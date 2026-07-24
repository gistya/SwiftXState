import JavaScriptKit
import SwiftXState

// The interactive signal-mesh app (main thread). Owns the SwiftXState actor tree (one router
// + N node children), a per-frame step/render loop, and a 2-D canvas. Nodes communicate only
// through the router (real `sendToParent` / `sendTo`); this file just steps the clock, reads
// each node's state from the router's `snapshot.children`, and draws.

// MARK: - Tiny DOM helper (adapted from Examples/WasmInspector/DOM.swift)

@MainActor
enum DOM {
    static var document: JSValue { JSObject.global.document }
    static var retained: [JSClosure] = []

    @discardableResult
    static func el(_ tag: String, _ cls: String? = nil, text: String? = nil) -> JSValue {
        let e = document.createElement(tag)
        if let cls { e.className = .string(cls) }
        if let text { e.textContent = .string(text) }
        return e
    }

    @discardableResult
    static func append(_ parent: JSValue, _ children: JSValue...) -> JSValue {
        for child in children { _ = parent.appendChild(child) }
        return parent
    }

    static func onClick(_ e: JSValue, _ handler: @escaping () -> Void) {
        let closure = JSClosure { _ in MainActor.assumeIsolated { handler() }; return .undefined }
        retained.append(closure)
        _ = e.addEventListener("click", closure)
    }

    /// Click handler that receives the DOM event (for canvas hit-testing).
    static func onEvent(_ e: JSValue, _ type: String, _ handler: @escaping (JSValue) -> Void) {
        let closure = JSClosure { args in MainActor.assumeIsolated { handler(args.first ?? .undefined) }; return .undefined }
        retained.append(closure)
        _ = e.addEventListener(type, closure)
    }

    static func injectStyle(_ css: String) {
        let style = document.createElement("style")
        style.textContent = .string(css)
        _ = document.head.appendChild(style)
    }
}

@MainActor func now() -> Double { JSObject.global.performance.now().number ?? 0 }

/// Await ~`ms` milliseconds via `setTimeout`. Deliberately NOT `requestAnimationFrame`:
/// rAF is fully paused on a hidden/background tab, which would freeze the whole simulation;
/// `setTimeout` keeps ticking (throttled in the background, full-rate when visible).
@MainActor func sleepFrame(_ ms: Double) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let setTimeout = JSObject.global.setTimeout.function!
        _ = setTimeout(JSOneshotClosure { _ in cont.resume(); return .undefined }, ms)
    }
}

// MARK: - App

@MainActor
final class MeshApp {
    // Grid + timing knobs.
    static let gridW = 6, gridH = 4
    let threshold = 1, refractory = 4
    let paceEvery = 16         // when the pacemaker is on, stimulate the centre every N steps

    let topo = makeTopology(w: gridW, h: gridH)
    let router: Actor<MachineLogic<RouterContext>>

    // Canvas.
    let cw = 760.0, ch = 470.0
    var ctx: JSValue = .undefined
    var pos: [(x: Double, y: Double)] = []

    // Visual afterglow durations (ms): bright flash, then a fading refractory glow.
    let flashMs = 150.0, glowMs = 700.0

    // Live view state. `lastFired[i]` = when node i last fired (ms); the renderer derives its
    // colour from the elapsed time. Fed by the router's `justFired`, so it never depends on
    // child-snapshot syncing.
    var lastFired: [Double]
    var pulses: [(from: Int, to: Int, start: Double)] = []
    var fires = 0
    var paced = false          // calm by default — click a node (or the pacemaker) to inject waves
    var pace = 0
    var lastStep = 0.0
    var stepMs = 120.0

    // DOM refs.
    let statEl = DOM.el("span", "stat", text: "—")
    let paceBtn = DOM.el("button", "btn", text: "▶ Pacemaker")

    init() {
        router = createActor(makeRouter(topo, threshold: threshold, refractory: refractory))
        lastFired = Array(repeating: -1e9, count: topo.n)
    }

    // MARK: build page

    func mount() {
        DOM.injectStyle(css)
        guard let doc = JSObject.global.document.object else { return }
        let body = doc.body
        body.innerHTML = .string("")

        let wrap = DOM.el("div", "wrap")
        let head = DOM.el("header")
        DOM.append(head,
            DOM.el("h1", text: "SwiftXState · signal mesh"),
            DOM.el("p", "sub", text: "\(topo.n) node actors, each its own SwiftXState machine (resting → firing → refractory), invoked as children of one router. Nodes don't address each other — a node fires, sends the router `FIRED`, and the router relays a `PULSE` to its graph-neighbours. Real spawn + sendToParent + sendTo; excitation spreads one ring per frame. Click any node to inject a signal."))

        let canvas = DOM.el("canvas", "mesh")
        canvas.width = .number(cw)
        canvas.height = .number(ch)
        ctx = canvas.getContext("2d")
        DOM.onEvent(canvas, "click") { [weak self] ev in self?.handleClick(ev) }

        let controls = DOM.el("div", "controls")
        let stimBtn = DOM.el("button", "btn primary", text: "◎ Stimulate centre")
        let resetBtn = DOM.el("button", "btn ghost", text: "Reset")
        DOM.onClick(stimBtn) { [weak self] in self?.stimulate(self?.topo.center ?? 0) }
        DOM.onClick(paceBtn) { [weak self] in self?.togglePace() }
        DOM.onClick(resetBtn) { [weak self] in self?.reset() }
        DOM.append(controls, stimBtn, paceBtn, resetBtn, statEl)

        DOM.append(wrap, head, canvas, controls,
            DOM.el("p", "sub small", text: "Each frame the router broadcasts TICK to all nodes; charged nodes fire; the router turns each firing into pulses to neighbours. Colliding wavefronts annihilate in the refractory shadow — the same excitable-medium behaviour as neurons or heart tissue."))
        _ = body.appendChild(wrap)

        computePositions()
        Task { await run() }
    }

    private func computePositions() {
        let mx = 52.0, my = 52.0
        let sx = (cw - 2 * mx) / Double(topo.w - 1)
        let sy = (ch - 2 * my) / Double(topo.h - 1)
        pos = (0..<topo.n).map { i in
            let (x, y) = topo.xy(i)
            return (mx + Double(x) * sx, my + Double(y) * sy)
        }
    }

    // MARK: run loop

    private func run() async {
        _ = await router.start()
        stimulate(topo.center)          // seed a first wave
        lastStep = now()
        // ~10 Hz. Deliberately unhurried: a tight loop would monopolise the single JS thread
        // (35 cross-boundary actor sends + a canvas redraw per frame), starving clicks.
        while true { await oneStep(); await sleepFrame(100) }
    }

    /// One simulation frame: read the settled result of the previous STEP, (optionally) pace,
    /// broadcast the next STEP, and repaint.
    private func oneStep() async {
        await refresh()
        if paced { pace += 1; if pace % paceEvery == 0 { await send("STIM#\(topo.center)") } }
        await send("STEP")
        let t = now(); stepMs = max(30, min(400, t - lastStep)); lastStep = t
        render()
    }

    private func send(_ type: String) async { await router.send(Event(type)) }

    /// Read the router's own context (always current, unlike the child-snapshot map): which
    /// nodes fired last step. Light each up and launch pulses toward its neighbours.
    private func refresh() async {
        let snap = await router.snapshot
        fires = snap.context.fires
        let t = now()
        for i in snap.context.justFired where i >= 0 && i < topo.n {
            lastFired[i] = t
            for j in topo.adj[i] { pulses.append((from: i, to: j, start: t)) }
        }
        pulses.removeAll { t - $0.start > stepMs * 1.3 }
        let active = lastFired.reduce(0) { $0 + (t - $1 < glowMs ? 1 : 0) }
        statEl.textContent = .string("\(topo.n) nodes · \(active) active · \(fires) total fires")
    }

    // MARK: input

    private func handleClick(_ ev: JSValue) {
        let x = ev.offsetX.number ?? -1, y = ev.offsetY.number ?? -1
        var best = -1, bestD = 26.0
        for i in 0..<topo.n {
            let dx = pos[i].x - x, dy = pos[i].y - y
            let d = (dx * dx + dy * dy).squareRoot()
            if d < bestD { bestD = d; best = i }
        }
        if best >= 0 { stimulate(best) }
    }

    private func stimulate(_ i: Int) { Task { await send("STIM#\(i)") } }
    private func reset() { Task { await send("RESET"); pulses.removeAll() } }
    private func togglePace() {
        paced.toggle()
        paceBtn.textContent = .string(paced ? "⏸ Pacemaker" : "▶ Pacemaker")
        paceBtn.className = .string(paced ? "btn primary" : "btn")
    }

    // MARK: render

    private func render() {
        let g = ctx
        g.fillStyle = .string("#0a0e13")
        _ = g.fillRect(0, 0, cw, ch)

        // edges
        g.strokeStyle = .string("#1b2431")
        g.lineWidth = .number(1.5)
        for i in 0..<topo.n {
            for j in topo.adj[i] where j > i {
                _ = g.beginPath()
                _ = g.moveTo(pos[i].x, pos[i].y)
                _ = g.lineTo(pos[j].x, pos[j].y)
                _ = g.stroke()
            }
        }

        // travelling pulses
        let t = now()
        g.fillStyle = .string("#7ee3c1")
        for p in pulses {
            let prog = min(1.0, max(0.0, (t - p.start) / stepMs))
            let x = pos[p.from].x + (pos[p.to].x - pos[p.from].x) * prog
            let y = pos[p.from].y + (pos[p.to].y - pos[p.from].y) * prog
            g.globalAlpha = .number(1.0 - prog * 0.5)
            _ = g.beginPath(); _ = g.arc(x, y, 3.5, 0, 6.28318); _ = g.fill()
        }
        g.globalAlpha = .number(1.0)

        // nodes — colour by time since last firing: bright flash → fading blue → resting
        for i in 0..<topo.n {
            let age = t - lastFired[i]
            if age < flashMs {
                g.shadowBlur = .number(22); g.shadowColor = .string("#ffe36b")
                g.fillStyle = .string("#ffe36b")
            } else if age < glowMs {
                g.shadowBlur = .number(0)
                g.fillStyle = .string("#2f5f9e")     // refractory afterglow
            } else {
                g.shadowBlur = .number(0)
                g.fillStyle = .string("#33414f")     // resting
            }
            _ = g.beginPath(); _ = g.arc(pos[i].x, pos[i].y, 13, 0, 6.28318); _ = g.fill()
        }
        g.shadowBlur = .number(0)
    }
}

@MainActor private var app: MeshApp?

@MainActor func runMesh() {
    let a = MeshApp()
    app = a               // retain for the life of the page
    a.mount()
}

// MARK: - Styles

@MainActor let css = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: #0c0f14; color: #e7ecf3;
  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
.wrap { max-width: 820px; margin: 0 auto; padding: 26px 20px 60px; }
header h1 { margin: 0 0 6px; font-size: 22px; }
.sub { color: #9aa7b8; margin: 0 0 18px; max-width: 70ch; }
.sub.small { font-size: 13px; margin-top: 16px; }
canvas.mesh { width: 100%; max-width: 760px; height: auto; display: block;
  background: #0a0e13; border: 1px solid #1c2431; border-radius: 14px; touch-action: none; cursor: crosshair; }
.controls { display: flex; align-items: center; gap: 10px; margin-top: 14px; flex-wrap: wrap; }
.btn { appearance: none; border: 1px solid #2c3a4f; cursor: pointer; padding: 9px 14px;
  border-radius: 10px; background: #1b2431; color: #e7ecf3; font-weight: 600; font-size: 14px;
  transition: background .15s; }
.btn:hover { background: #223047; }
.btn.primary { background: #1f6feb; border-color: #2f7bf0; }
.btn.primary:hover { background: #2a7cf7; }
.btn.ghost { background: transparent; }
.stat { margin-left: auto; color: #7ee3c1; font: 600 13px ui-monospace, Menlo, monospace; }
"""
