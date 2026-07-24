import JavaScriptKit
import SwiftXStateDistributed

// The interactive control room (main-thread only). Two SwiftXState machines run as
// `distributed actor`s in two separate Web Workers; every button here makes a real
// distributed call and re-renders from the returned Codable `MachineReport`.

// MARK: - Tiny DOM layer over JavaScriptKit (adapted from Examples/WasmInspector/DOM.swift)

@MainActor
enum DOM {
    static var document: JSValue { JSObject.global.document }

    /// Listener closures must outlive the call that registers them, or JS calls into freed
    /// memory. The page is long-lived, so we retain every one for its lifetime.
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
        let closure = JSClosure { _ in
            MainActor.assumeIsolated { handler() }
            return .undefined
        }
        retained.append(closure)
        _ = e.addEventListener("click", closure)
    }

    static func injectStyle(_ css: String) {
        let style = document.createElement("style")
        style.textContent = .string(css)
        _ = document.head.appendChild(style)
    }
}

@MainActor func now() -> Double { JSObject.global.performance.now().number ?? 0 }

// MARK: - Control room

@MainActor
final class ControlRoom {
    // The two workers (each a distributed actor in its own Web Worker).
    private var counter: CounterWorker!
    private var traffic: TrafficWorker!

    // How hard the parallelism demo hits each worker. Enough to be visible; tune freely.
    private let busyRounds = 45_000_000
    private var lastSeq: Double?
    private var lastPar: Double?

    // Counter card refs.
    private let cState  = DOM.el("span", "pill")
    private let cValue  = DOM.el("div", "big", text: "–")
    private let cFill   = DOM.el("div", "meter-fill")
    private let cDec    = DOM.el("button", "btn", text: "− DEC")
    private let cInc    = DOM.el("button", "btn primary", text: "+ INC")
    private let cReset  = DOM.el("button", "btn ghost", text: "RESET")

    // Traffic card refs.
    private let tRed    = DOM.el("div", "bulb red")
    private let tYellow = DOM.el("div", "bulb yellow")
    private let tGreen  = DOM.el("div", "bulb green")
    private let tName   = DOM.el("span", "pill")
    private let tNext   = DOM.el("button", "btn primary", text: "NEXT ▸")
    private let tWalk   = DOM.el("button", "btn", text: "🚶 WALK")
    private let tCycles = DOM.el("span", "chip", text: "cycles 0")
    private let tPeds   = DOM.el("span", "chip", text: "walks 0")

    // Parallelism panel refs.
    private let pSeq     = DOM.el("button", "btn", text: "Run sequentially")
    private let pPar     = DOM.el("button", "btn primary", text: "Run in parallel")
    private let pSpinner = DOM.el("div", "spinner idle")
    private let pResult  = DOM.el("div", "presult", text: "—")

    private let logEl = DOM.el("pre", "log", text: "")

    func mount() {
        DOM.injectStyle(css)
        // Reach `body` through JSObject: a bare `.body` read on a JSValue is an ambiguous
        // dynamic-member lookup, whereas member access on a JSObject is unambiguous. `doc.body`
        // yields a JSValue, on which method calls need no `!` (unlike JSObject members).
        guard let doc = JSObject.global.document.object else { return }
        let body = doc.body
        body.innerHTML = .string("")

        let wrap = DOM.el("div", "wrap")
        DOM.append(wrap, header(), workersRow(), parallelPanel(), logCard())
        _ = body.appendChild(wrap)

        // All controls start disabled until the workers boot and the first report arrives.
        for b in [cDec, cInc, cReset, tNext, tWalk, pSeq, pPar] { b.disabled = .boolean(true) }

        wire()
        Task { await boot() }
    }

    // MARK: build

    private func header() -> JSValue {
        let h = DOM.el("header")
        DOM.append(h,
            DOM.el("h1", text: "SwiftXState · distributed actors"),
            DOM.el("p", "sub", text: "Two state machines, each running inside its own Web Worker (a separate OS thread) as a Swift distributed actor. Every click below is a real cross-worker call; the arguments and the returned snapshot travel as Codable.")
        )
        return h
    }

    private func workersRow() -> JSValue {
        let row = DOM.el("div", "row")
        DOM.append(row, counterCard(), trafficCard())
        return row
    }

    private func counterCard() -> JSValue {
        let card = DOM.el("div", "card")
        let head = DOM.el("div", "card-head")
        DOM.append(head,
            DOM.el("span", "worker-badge", text: "Worker #1"),
            DOM.el("h2", text: "CounterWorker"))
        let stateRow = DOM.el("div", "state-row")
        cState.textContent = .string("…")
        DOM.append(stateRow, DOM.el("span", "muted", text: "state"), cState)

        let meter = DOM.el("div", "meter")
        _ = meter.appendChild(cFill)

        let btns = DOM.el("div", "btns")
        DOM.append(btns, cDec, cInc, cReset)

        DOM.append(card, head, stateRow, cValue,
            DOM.el("div", "muted small", text: "bounded to [0, 10] — guards make the worker report which buttons are legal"),
            meter, btns)
        return card
    }

    private func trafficCard() -> JSValue {
        let card = DOM.el("div", "card")
        let head = DOM.el("div", "card-head")
        DOM.append(head,
            DOM.el("span", "worker-badge", text: "Worker #2"),
            DOM.el("h2", text: "TrafficWorker"))
        let stateRow = DOM.el("div", "state-row")
        tName.textContent = .string("…")
        DOM.append(stateRow, DOM.el("span", "muted", text: "state"), tName)

        let housing = DOM.el("div", "housing")
        DOM.append(housing, tRed, tYellow, tGreen)

        let btns = DOM.el("div", "btns")
        DOM.append(btns, tNext, tWalk)

        let stats = DOM.el("div", "stats")
        DOM.append(stats, tCycles, tPeds)

        DOM.append(card, head, stateRow, housing,
            DOM.el("div", "muted small", text: "WALK exists only on red — the button lights up exactly when the machine allows it"),
            btns, stats)
        return card
    }

    private func parallelPanel() -> JSValue {
        let card = DOM.el("div", "card wide")
        DOM.append(card,
            DOM.el("h2", text: "Two threads, for real"),
            DOM.el("p", "sub", text: "Run the same CPU burn on both workers. Sequentially it costs ~2× the time; in parallel the two workers overlap on two cores. The spinner keeps turning the whole time — proof the UI thread is never blocked, because the work is off on the workers."))
        let controls = DOM.el("div", "prow")
        DOM.append(controls, pSeq, pPar, pSpinner)
        DOM.append(card, controls, pResult)
        return card
    }

    private func logCard() -> JSValue {
        let card = DOM.el("div", "card wide")
        DOM.append(card, DOM.el("h2", "log-h", text: "wire log"), logEl)
        return card
    }

    // MARK: wiring

    private func wire() {
        DOM.onClick(cInc)   { self.send1("INC") }
        DOM.onClick(cDec)   { self.send1("DEC") }
        DOM.onClick(cReset) { self.send1("RESET") }
        DOM.onClick(tNext)  { self.send2("NEXT") }
        DOM.onClick(tWalk)  { self.send2("WALK") }
        DOM.onClick(pSeq)   { self.runBurn(parallel: false) }
        DOM.onClick(pPar)   { self.runBurn(parallel: true) }
    }

    private func send1(_ event: String) {
        run("counter \(event)") {
            let r = try await self.counter.send(event)
            self.renderCounter(r)
            self.log("→ counter.send(\(event))  ⇒  value=\(r.context.value)  enabled=\(r.enabled)")
        }
    }

    private func send2(_ event: String) {
        run("traffic \(event)") {
            let r = try await self.traffic.send(event)
            self.renderTraffic(r)
            self.log("→ traffic.send(\(event))  ⇒  \(r.state)  cycles=\(r.context.cycles) walks=\(r.context.peds)")
        }
    }

    // MARK: render

    private func renderCounter(_ r: MachineReport<CounterContext>) {
        cState.textContent = .string(r.state)
        cValue.textContent = .string("\(r.context.value)")
        _ = cFill.setAttribute("style", "width:\(r.context.value * 10)%")
        cInc.disabled   = .boolean(!r.enabled.contains("INC"))
        cDec.disabled   = .boolean(!r.enabled.contains("DEC"))
        cReset.disabled = .boolean(!r.enabled.contains("RESET"))
    }

    private func renderTraffic(_ r: MachineReport<TrafficContext>) {
        tName.textContent = .string(r.state)
        tRed.className    = .string(r.state == "red"    ? "bulb red on"    : "bulb red")
        tYellow.className = .string(r.state == "yellow" ? "bulb yellow on" : "bulb yellow")
        tGreen.className  = .string(r.state == "green"  ? "bulb green on"  : "bulb green")
        tNext.disabled = .boolean(!r.enabled.contains("NEXT"))
        tWalk.disabled = .boolean(!r.enabled.contains("WALK"))
        tCycles.textContent = .string("cycles \(r.context.cycles)")
        tPeds.textContent   = .string("walks \(r.context.peds)")
    }

    // MARK: parallelism demo

    private func runBurn(parallel: Bool) {
        pSeq.disabled = .boolean(true)
        pPar.disabled = .boolean(true)
        pSpinner.className = .string("spinner")
        pResult.textContent = .string(parallel ? "running on both workers at once…" : "running one worker after the other…")
        run("burn") {
            let t0 = now()
            if parallel {
                // Kick off both distributed calls, then await both. Each posts to a different
                // worker and suspends, so the two workers burn CPU on two cores at once.
                let jobA = Task { try await self.counter.busy(self.busyRounds) }
                let jobB = Task { try await self.traffic.busy(self.busyRounds) }
                _ = try await jobA.value
                _ = try await jobB.value
            } else {
                _ = try await self.counter.busy(self.busyRounds)
                _ = try await self.traffic.busy(self.busyRounds)
            }
            let dt = now() - t0
            if parallel { self.lastPar = dt } else { self.lastSeq = dt }
            self.pSpinner.className = .string("spinner idle")
            self.pSeq.disabled = .boolean(false)
            self.pPar.disabled = .boolean(false)
            self.showBurnResult(latest: parallel ? "parallel" : "sequential", dt: dt)
            self.log("⚙︎ \(parallel ? "parallel" : "sequential") burn: \(Int(dt)) ms")
        }
    }

    private func showBurnResult(latest: String, dt: Double) {
        var line = "\(latest): \(Int(dt)) ms"
        if let s = lastSeq, let p = lastPar, p > 0 {
            let x = (s / p * 10).rounded() / 10
            line = "sequential \(Int(s)) ms · parallel \(Int(p)) ms · ≈ \(x)× faster on two workers"
        }
        pResult.textContent = .string(line)
    }

    // MARK: boot + plumbing

    private func boot() async {
        do {
            log("spawning two Web Workers (CounterWorker, TrafficWorker)…")
            counter = try CounterWorker.new()
            traffic = try TrafficWorker.new()
            renderCounter(try await counter.report())
            renderTraffic(try await traffic.report())
            pSeq.disabled = .boolean(false)
            pPar.disabled = .boolean(false)
            log("ready — both machines are live inside their workers. Click away.")
        } catch {
            log("boot error: \(error)")
        }
    }

    /// Run an async body, surfacing any error to the log. Task inherits MainActor isolation.
    private func run(_ label: String, _ body: @escaping () async throws -> Void) {
        Task {
            do { try await body() } catch { log("\(label) error: \(error)") }
        }
    }

    private func log(_ s: String) {
        print(s)
        let prev = logEl.textContent.string ?? ""
        // Keep the last ~40 lines so the log stays readable.
        var lines = (prev + s + "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 41 { lines = Array(lines.suffix(41)) }
        logEl.textContent = .string(lines.joined(separator: "\n"))
        logEl.scrollTop = logEl.scrollHeight     // keep the newest line in view
    }
}

@MainActor private var room: ControlRoom?

@MainActor func runControlRoom() {
    let r = ControlRoom()
    room = r          // retain for the life of the page
    r.mount()
}

// MARK: - Styles

@MainActor private let css = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body {
  margin: 0; background: #0c0f14; color: #e7ecf3;
  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
}
.wrap { max-width: 900px; margin: 0 auto; padding: 28px 20px 60px; }
header h1 { margin: 0 0 6px; font-size: 22px; letter-spacing: .2px; }
.sub { color: #9aa7b8; margin: 0 0 20px; max-width: 62ch; }
h2 { margin: 0 0 12px; font-size: 16px; }
.row { display: flex; gap: 16px; flex-wrap: wrap; }
.card {
  flex: 1 1 300px; background: #141922; border: 1px solid #232c3a;
  border-radius: 16px; padding: 18px 18px 20px; box-shadow: 0 1px 0 #0006;
}
.card.wide { flex-basis: 100%; margin-top: 16px; }
.card-head { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
.card-head h2 { margin: 0; }
.worker-badge {
  font: 600 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: #7ee3c1;
  background: #103028; border: 1px solid #1c5443; padding: 2px 8px; border-radius: 999px;
}
.muted { color: #8a97a8; } .small { font-size: 12px; }
.state-row { display: flex; align-items: center; gap: 8px; margin: 4px 0 8px; }
.pill {
  font: 600 12px ui-monospace, Menlo, monospace; color: #cfe0ff;
  background: #172236; border: 1px solid #27374f; padding: 3px 10px; border-radius: 999px;
}
.big { font-size: 56px; font-weight: 700; line-height: 1; margin: 6px 0 10px; }
.meter { height: 10px; background: #0d1219; border: 1px solid #232c3a; border-radius: 999px; overflow: hidden; }
.meter-fill {
  height: 100%; width: 0%;
  background: linear-gradient(90deg, #3aa0ff, #7ee3c1);
  transition: width .22s cubic-bezier(.2,.7,.3,1);
}
.btns { display: flex; gap: 8px; margin-top: 16px; flex-wrap: wrap; }
.btn {
  appearance: none; border: 1px solid #2c3a4f; cursor: pointer;
  padding: 9px 14px; border-radius: 10px;
  background: #1b2431; color: #e7ecf3; font-weight: 600; font-size: 14px;
  transition: transform .05s ease, background .15s, opacity .15s;
}
.btn:hover:not(:disabled) { background: #223047; }
.btn:active:not(:disabled) { transform: translateY(1px); }
.btn.primary { background: #1f6feb; border-color: #2f7bf0; }
.btn.primary:hover:not(:disabled) { background: #2a7cf7; }
.btn.ghost { background: transparent; }
.btn:disabled { opacity: .35; cursor: not-allowed; }
.housing {
  display: inline-flex; flex-direction: column; gap: 12px; align-items: center;
  background: #05070a; border: 1px solid #202834; border-radius: 16px; padding: 14px; margin: 4px 0;
}
.bulb { width: 46px; height: 46px; border-radius: 50%; opacity: .16; transition: opacity .2s, box-shadow .2s; }
.bulb.red { background: #ff4d4d; } .bulb.yellow { background: #ffcc33; } .bulb.green { background: #37d67a; }
.bulb.on { opacity: 1; }
.bulb.red.on { box-shadow: 0 0 22px 4px #ff4d4daa; }
.bulb.yellow.on { box-shadow: 0 0 22px 4px #ffcc33aa; }
.bulb.green.on { box-shadow: 0 0 22px 4px #37d67aaa; }
.stats { display: flex; gap: 8px; margin-top: 14px; }
.chip {
  font: 600 12px ui-monospace, Menlo, monospace; color: #b9c6d8;
  background: #141c28; border: 1px solid #263349; padding: 4px 10px; border-radius: 8px;
}
.prow { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.presult { margin-top: 14px; font: 600 14px ui-monospace, Menlo, monospace; color: #7ee3c1; }
.spinner {
  width: 22px; height: 22px; border-radius: 50%;
  border: 3px solid #2a3547; border-top-color: #7ee3c1;
  animation: spin .8s linear infinite;
}
.spinner.idle { animation: none; opacity: .25; border-top-color: #2a3547; }
@keyframes spin { to { transform: rotate(360deg); } }
.log-h { color: #8a97a8; font-size: 13px; text-transform: uppercase; letter-spacing: .08em; }
.log {
  margin: 0; max-height: 220px; overflow: auto; white-space: pre-wrap;
  font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; color: #9fb3c9;
  background: #0a0e13; border: 1px solid #1c2431; border-radius: 10px; padding: 12px;
}
"""
