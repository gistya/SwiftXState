import Foundation
import JavaScriptKit
import JavaScriptEventLoop
import SwiftWebGPU

/// A reusable, GPU-accelerated state-machine graph renderer for the browser (Swift → WebAssembly →
/// WebGPU). Point it at an XState-style machine-definition JSON and a `<canvas>` element; it parses
/// the states/transitions into a graph, runs a **force-directed layout**, and renders interactive,
/// animated nodes + edges + arrowheads + **GPU text labels** (a glyph atlas — no HTML overlay). The
/// active state is highlighted (eased animation + pulse); tapping a node fires `onSelect`.
///
/// Camera: **drag** to rotate, **two-finger scroll** to pan, **pinch / ctrl-scroll** to zoom — all
/// applied in the vertex shader so labels, edges and nodes transform together.
///
/// Single active instance per page (it keeps its GPU state in module globals). Depends only on
/// JavaScriptKit + swift-webgpu — not on any particular state-machine library.
///
/// ```swift
/// await StateGraph.start(canvasElementId: "gpu", definitionJSON: try machine.definitionJSON()) { name in
///     print("tapped", name)
/// }
/// // after each transition:
/// StateGraph.setActiveState(actor.snapshot.value.description)
/// ```
@MainActor
public enum StateGraph {
    /// Set up the GPU and start the render loop. `definitionJSON` is XState-shaped
    /// (`{ states: { name: { on: { EVENT: <target(s)> } } } }`).
    /// Text mode for the labels:
    /// - `.msdf` (default) loads the embedded true multi-channel atlas — razor-sharp corners at any
    ///   zoom, no per-load compute. Requires the atlas (`msdf.png`/`msdf.json`) to be served; if it
    ///   isn't, it falls back to `.sdf` automatically.
    /// - `.sdf` builds a single-channel distance field in Swift at load — fully self-contained (no
    ///   asset), but pays a one-time distance-transform cost (~½ s for ASCII).
    public enum TextMode: Sendable { case sdf, msdf }

    public static func start(
        canvasElementId: String,
        definitionJSON: String,
        textMode: TextMode = .msdf,
        onSelect: ((String) -> Void)? = nil
    ) async {
        await GraphState.shared.start(canvasElementId: canvasElementId, definitionJSON: definitionJSON,
                                      textMode: textMode, onSelect: onSelect)
    }

    /// Tell the renderer which state is active now (e.g. `actor.snapshot.value.description`).
    /// The highlight eases smoothly toward the new node.
    public static func setActiveState(_ name: String) {
        GraphState.shared.setActiveState(name)
    }

    /// The state names parsed from the definition, in layout order.
    public static var nodeNames: [String] { GraphState.shared.names }
}

// MARK: - Minimal JSON (so the toolkit needn't depend on a state-machine library)

private indirect enum JSON: Decodable {
    case string(String), number(Double), bool(Bool), object([String: JSON]), array([JSON]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .null }
    }
}

// MARK: - Renderer

@MainActor
final class GraphState {
    static let shared = GraphState()

    // Graph
    var names: [String] = []
    private var edges: [(Int, Int)] = []
    private var centers: [(x: Double, y: Double)] = []
    private var vel: [(x: Double, y: Double)] = []   // force-directed layout velocities
    private var activation: [Double] = []   // eased current
    private var target: [Double] = []       // 0/1 goal
    private var selected: Int?
    private var onSelect: ((String) -> Void)?

    // Distance-field text: a font atlas + per-glyph quads rebuilt each frame so labels ride nodes.
    private var fontAtlas: FontAtlas?
    private var useMSDF = false
    private var glyphCount: UInt32 = 0
    private let labelEm = 0.072   // world units per em (label size)

    // Camera: rotation (drag), pan (two-finger scroll), zoom (pinch / ctrl-scroll).
    private var angle = 0.0
    private var zoom = 1.0
    private var panX = 0.0
    private var panY = 0.0
    private var dragging = false
    private var dragStartX = 0.0
    private var dragStartAngle = 0.0
    private var dragMoved = 0.0

    // GPU
    private var device: GPUDevice?
    private var context: GPUCanvasContext?
    private var edgePipe: GPURenderPipeline?
    private var arrowPipe: GPURenderPipeline?
    private var nodePipe: GPURenderPipeline?
    private var textPipe: GPURenderPipeline?
    private var bindGroup: GPUBindGroup?
    private var textBindGroup: GPUBindGroup?
    private var uniform: GPUBuffer?
    private var quad: GPUBuffer?
    private var nodeInst: GPUBuffer?
    private var edgeInst: GPUBuffer?
    private var arrowInst: GPUBuffer?
    private var textInst: GPUBuffer?
    private var textParamsBuf: GPUBuffer?
    private var msaaView: GPUTextureView?
    private let sampleCount: UInt32 = 4
    private var aspect = 1.0

    private var frameLoop: JSClosure?
    private var canvasEl: JSObject?
    private var pointerClosures: [JSClosure] = []

    private let ringR = 0.72       // seed radius for the layout
    private let nodeR = 0.12
    private let arrowSize = 0.045

    // Node visual half-extents in world units (must match fs_node's bExt * the node quad half-size).
    private var nodeHalfW: Double { 0.66 * nodeR * 1.8 }
    private var nodeHalfH: Double { 0.46 * nodeR * 1.8 }

    private func f32(_ v: [Double]) -> JSObject { JSObject.global.Float32Array.function!.new(v) }
    private func status(_ s: String) {
        let el = JSObject.global.document.getElementById("status")
        el.innerText = .string(s)
    }

    // MARK: Parse

    private func parse(_ json: String) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSON.self, from: data),
              case let .object(obj) = root, case let .object(states)? = obj["states"] else { return }
        names = states.keys.sorted()
        let idx = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        func last(_ s: String) -> String {
            var t = s
            if t.hasPrefix("#") { t.removeFirst() }
            return t.split(separator: ".").last.map(String.init) ?? t
        }
        var seen = Set<String>()
        for name in names {
            guard case let .object(node)? = states[name], case let .object(on)? = node["on"] else { continue }
            for (_, trans) in on {
                let items: [JSON] = { if case let .array(a) = trans { return a } else { return [trans] } }()
                for t in items {
                    var tgt: String?
                    if case let .string(s) = t { tgt = s }
                    else if case let .object(o) = t, let tv = o["target"] {
                        if case let .string(s) = tv { tgt = s }
                        else if case let .array(a) = tv, case let .string(s)? = a.first { tgt = s }
                    }
                    guard let ts = tgt, let si = idx[name], let di = idx[last(ts)], si != di else { continue }
                    if seen.insert("\(si)>\(di)").inserted { edges.append((si, di)) }
                }
            }
        }
    }

    // MARK: Layout (seed ring, then force-directed simulation each frame)

    private func layout() {
        let n = max(names.count, 1)
        centers = names.indices.map { i in
            let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
            return (cos(a) * ringR, sin(a) * ringR)
        }
        vel = Array(repeating: (0, 0), count: names.count)
        activation = Array(repeating: 0, count: names.count)
        target = Array(repeating: 0, count: names.count)
    }

    /// One step of a small force-directed layout: nodes repel, edges act as springs, a gentle pull
    /// keeps the graph centred. Cheap for the handful of states in a typical machine.
    private func simulate() {
        let n = centers.count
        guard n > 1 else { return }
        let kRep = 0.045, kSpring = 2.6, rest = 0.62, kCenter = 0.9, damp = 0.86, dt = 0.18
        var fx = [Double](repeating: 0, count: n)
        var fy = [Double](repeating: 0, count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                var dx = centers[i].x - centers[j].x
                var dy = centers[i].y - centers[j].y
                var d2 = dx * dx + dy * dy
                if d2 < 1e-4 { dx = 0.01; dy = 0.01; d2 = 2e-4 }   // de-overlap coincident nodes
                let d = d2.squareRoot()
                let f = kRep / d2
                let ux = dx / d, uy = dy / d
                fx[i] += ux * f; fy[i] += uy * f
                fx[j] -= ux * f; fy[j] -= uy * f
            }
        }
        for (a, b) in edges {
            let dx = centers[b].x - centers[a].x, dy = centers[b].y - centers[a].y
            let d = max((dx * dx + dy * dy).squareRoot(), 1e-4)
            let ff = kSpring * (d - rest)
            let ux = dx / d, uy = dy / d
            fx[a] += ux * ff; fy[a] += uy * ff
            fx[b] -= ux * ff; fy[b] -= uy * ff
        }
        for i in 0..<n {
            fx[i] -= kCenter * centers[i].x
            fy[i] -= kCenter * centers[i].y
        }
        var maxStep = 0.0
        for i in 0..<n {
            vel[i].x = (vel[i].x + fx[i] * dt) * damp
            vel[i].y = (vel[i].y + fy[i] * dt) * damp
            var sx = vel[i].x * dt, sy = vel[i].y * dt
            let sp = (sx * sx + sy * sy).squareRoot()
            if sp > 0.05 { sx *= 0.05 / sp; sy *= 0.05 / sp }   // clamp per-frame travel for stability
            centers[i].x += sx; centers[i].y += sy
            maxStep = max(maxStep, abs(sx) + abs(sy))
        }
        _ = maxStep   // (could be used to stop the sim once settled; we let it idle harmlessly)
    }

    private func color(_ i: Int) -> (Double, Double, Double) {
        let p: [(Double, Double, Double)] = [
            (0.49, 0.36, 1.0), (0.18, 0.80, 0.55), (0.96, 0.62, 0.10),
            (0.93, 0.34, 0.45), (0.30, 0.70, 0.95), (0.95, 0.45, 0.85),
        ]
        return p[i % p.count]
    }

    // MARK: Public-ish

    func setActiveState(_ name: String) {
        for i in names.indices { target[i] = (names[i] == name) ? 1.0 : 0.0 }
    }

    // MARK: Start

    func start(canvasElementId: String, definitionJSON: String,
               textMode: StateGraph.TextMode, onSelect: ((String) -> Void)?) async {
        self.onSelect = onSelect
        self.useMSDF = (textMode == .msdf)
        parse(definitionJSON)
        layout()

        guard let gpu = GPU.shared else { status("WebGPU is not available in this browser."); return }
        let canvas = JSObject.global.document.getElementById(canvasElementId).object!
        let cw = canvas.width.number ?? 720
        let ch = canvas.height.number ?? 480
        aspect = ch / cw
        guard let adapter = await gpu.requestAdapter(), let dev = try? await adapter.requestDevice() else {
            status("Could not acquire a GPU device."); return
        }

        let ctx = GPUCanvasContext(jsObject: canvas.getContext!("webgpu").object!)
        let format = gpu.preferredCanvasFormat
        ctx.configure(GPUCanvasConfiguration(device: dev, format: format))
        let module = dev.createShaderModule(descriptor: GPUShaderModuleDescriptor(code: Self.wgsl))

        // 4× MSAA target — antialiases the edge/arrow geometry. Resolved into the canvas each frame.
        let msaa = dev.createTexture(descriptor: GPUTextureDescriptor(
            size: GPUExtent3D(width: UInt32(cw), height: UInt32(ch)),
            sampleCount: sampleCount, format: format, usage: [.renderAttachment]))
        msaaView = msaa.createView()
        let ms = GPUMultisampleState(count: sampleCount)

        func target0(_ format: GPUTextureFormat) -> GPUFragmentState {
            GPUFragmentState(module: module, entryPoint: "fs_solid", targets: [GPUColorTargetState(format: format)])
        }
        let quadL = GPUVertexBufferLayout(arrayStride: 8, stepMode: .vertex, attributes: [
            GPUVertexAttribute(format: .float32x2, offset: 0, shaderLocation: 0)])
        let edgeL = GPUVertexBufferLayout(arrayStride: 32, stepMode: .instance, attributes: [
            GPUVertexAttribute(format: .float32x2, offset: 0, shaderLocation: 1),
            GPUVertexAttribute(format: .float32x2, offset: 8, shaderLocation: 2),
            GPUVertexAttribute(format: .float32x3, offset: 16, shaderLocation: 3),
            GPUVertexAttribute(format: .float32, offset: 28, shaderLocation: 4)])
        let arrowL = GPUVertexBufferLayout(arrayStride: 32, stepMode: .instance, attributes: [
            GPUVertexAttribute(format: .float32x2, offset: 0, shaderLocation: 0),
            GPUVertexAttribute(format: .float32x2, offset: 8, shaderLocation: 1),
            GPUVertexAttribute(format: .float32x3, offset: 16, shaderLocation: 2),
            GPUVertexAttribute(format: .float32, offset: 28, shaderLocation: 3)])
        let nodeL = GPUVertexBufferLayout(arrayStride: 36, stepMode: .instance, attributes: [
            GPUVertexAttribute(format: .float32x2, offset: 0, shaderLocation: 1),
            GPUVertexAttribute(format: .float32x2, offset: 8, shaderLocation: 2),
            GPUVertexAttribute(format: .float32x3, offset: 16, shaderLocation: 3),
            GPUVertexAttribute(format: .float32, offset: 28, shaderLocation: 4),
            GPUVertexAttribute(format: .float32, offset: 32, shaderLocation: 5)])

        // Explicit shared layout so one bind group is compatible with all geometry pipelines
        // (auto layouts are per-pipeline and would not be interchangeable).
        let bgl = dev.createBindGroupLayout(descriptor: GPUBindGroupLayoutDescriptor(entries: [
            GPUBindGroupLayoutEntry(binding: 0, visibility: [.vertex, .fragment],
                                    buffer: GPUBufferBindingLayout(type: .uniform))]))
        let pipeLayout = dev.createPipelineLayout(descriptor: GPUPipelineLayoutDescriptor(bindGroupLayouts: [bgl]))

        edgePipe = dev.createRenderPipeline(descriptor: GPURenderPipelineDescriptor(
            vertex: GPUVertexState(module: module, entryPoint: "vs_edge", buffers: [quadL, edgeL]),
            multisample: ms, fragment: target0(format), layout: .layout(pipeLayout)))
        arrowPipe = dev.createRenderPipeline(descriptor: GPURenderPipelineDescriptor(
            vertex: GPUVertexState(module: module, entryPoint: "vs_arrow", buffers: [arrowL]),
            multisample: ms, fragment: target0(format), layout: .layout(pipeLayout)))
        nodePipe = dev.createRenderPipeline(descriptor: GPURenderPipelineDescriptor(
            vertex: GPUVertexState(module: module, entryPoint: "vs_node", buffers: [quadL, nodeL]),
            multisample: ms,
            fragment: GPUFragmentState(module: module, entryPoint: "fs_node",
                targets: [GPUColorTargetState(format: format, blend: .alphaBlending)]),
            layout: .layout(pipeLayout)))

        quad = dev.createBuffer(descriptor: GPUBufferDescriptor(size: 48, usage: [.vertex, .copyDst]))
        dev.queue.writeBuffer(quad!, bufferOffset: 0, data: f32([-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1]))
        nodeInst = dev.createBuffer(descriptor: GPUBufferDescriptor(size: UInt64(max(names.count, 1) * 36), usage: [.vertex, .copyDst]))
        edgeInst = dev.createBuffer(descriptor: GPUBufferDescriptor(size: UInt64(max(edges.count, 1) * 32), usage: [.vertex, .copyDst]))
        arrowInst = dev.createBuffer(descriptor: GPUBufferDescriptor(size: UInt64(max(edges.count, 1) * 32), usage: [.vertex, .copyDst]))
        let maxGlyphs = max(names.reduce(0) { $0 + $1.count }, 1)
        textInst = dev.createBuffer(descriptor: GPUBufferDescriptor(size: UInt64(maxGlyphs * 48), usage: [.vertex, .copyDst]))
        uniform = dev.createBuffer(descriptor: GPUBufferDescriptor(size: 32, usage: [.uniform, .copyDst]))
        bindGroup = dev.createBindGroup(descriptor: GPUBindGroupDescriptor(
            layout: bgl,
            entries: [GPUBindGroupEntry(binding: 0, resource: .buffer(uniform!))]))

        // Distance-field text labels (no HTML overlay): build a font atlas (SDF in Swift, or the
        // embedded MSDF), then a per-glyph text pipeline that samples it.
        await setupText(dev: dev, module: module, format: format, ms: ms, sharedBGL: bgl)

        device = dev; context = ctx; canvasEl = canvas
        installPointer(canvas)

        frameLoop = JSClosure { args in
            let ms = args.first?.number ?? 0
            MainActor.assumeIsolated { GraphState.shared.frame(ms / 1000.0) }
            return .undefined
        }
        _ = JSObject.global.requestAnimationFrame.function!(frameLoop!.jsValue)
    }

    // MARK: Distance-field text setup

    /// Build the font atlas (runtime SDF, or the embedded MSDF), then a per-glyph text pipeline that
    /// samples it with the screen-space-AA distance-field shader (`vs_glyph`/`fs_glyph`).
    private func setupText(dev: GPUDevice, module: GPUShaderModule, format: GPUTextureFormat,
                           ms: GPUMultisampleState, sharedBGL: GPUBindGroupLayout) async {
        guard !names.isEmpty else { return }
        let atlas: FontAtlas?
        if useMSDF {
            atlas = await MSDFFont.load(dev: dev)
            if atlas == nil { status("MSDF atlas unavailable — falling back to runtime SDF.") }
        } else {
            atlas = nil
        }
        guard let font = atlas ?? SDFFont.build(dev: dev) else { return }
        fontAtlas = font

        let sampler = dev.createSampler(descriptor: GPUSamplerDescriptor(magFilter: .linear, minFilter: .linear))
        // Text params uniform: pxRange + mode (0 = SDF / 1 = MSDF) + a dark outline width for contrast.
        textParamsBuf = dev.createBuffer(descriptor: GPUBufferDescriptor(size: 16, usage: [.uniform, .copyDst]))
        dev.queue.writeBuffer(textParamsBuf!, bufferOffset: 0,
                              data: f32([font.pxRange, Double(font.mode), 0.22, 0]))

        // group(1): atlas sampler + texture + the text-params uniform. group(0) stays the camera.
        let texBGL = dev.createBindGroupLayout(descriptor: GPUBindGroupLayoutDescriptor(entries: [
            GPUBindGroupLayoutEntry(binding: 0, visibility: [.fragment], sampler: GPUSamplerBindingLayout(type: .filtering)),
            GPUBindGroupLayoutEntry(binding: 1, visibility: [.fragment], texture: GPUTextureBindingLayout(sampleType: .float)),
            GPUBindGroupLayoutEntry(binding: 2, visibility: [.fragment], buffer: GPUBufferBindingLayout(type: .uniform))]))
        textBindGroup = dev.createBindGroup(descriptor: GPUBindGroupDescriptor(layout: texBGL, entries: [
            GPUBindGroupEntry(binding: 0, resource: .sampler(sampler)),
            GPUBindGroupEntry(binding: 1, resource: .textureView(font.view)),
            GPUBindGroupEntry(binding: 2, resource: .buffer(textParamsBuf!))]))

        let textLayout = dev.createPipelineLayout(descriptor: GPUPipelineLayoutDescriptor(bindGroupLayouts: [sharedBGL, texBGL]))
        let quadL = GPUVertexBufferLayout(arrayStride: 8, stepMode: .vertex, attributes: [
            GPUVertexAttribute(format: .float32x2, offset: 0, shaderLocation: 0)])
        // Per-glyph instance: worldMin@0, worldMax@8, uvMin@16, uvMax@24, color@32 = 48 bytes.
        let glyphL = GPUVertexBufferLayout(arrayStride: 48, stepMode: .instance, attributes: [
            GPUVertexAttribute(format: .float32x2, offset: 0, shaderLocation: 1),
            GPUVertexAttribute(format: .float32x2, offset: 8, shaderLocation: 2),
            GPUVertexAttribute(format: .float32x2, offset: 16, shaderLocation: 3),
            GPUVertexAttribute(format: .float32x2, offset: 24, shaderLocation: 4),
            GPUVertexAttribute(format: .float32x4, offset: 32, shaderLocation: 5)])
        textPipe = dev.createRenderPipeline(descriptor: GPURenderPipelineDescriptor(
            vertex: GPUVertexState(module: module, entryPoint: "vs_glyph", buffers: [quadL, glyphL]),
            multisample: ms,
            fragment: GPUFragmentState(module: module, entryPoint: "fs_glyph",
                targets: [GPUColorTargetState(format: format, blend: .alphaBlending)]),
            layout: .layout(textLayout)))
    }

    // MARK: Pointer + wheel input

    private func installPointer(_ canvas: JSObject) {
        let down = JSClosure { a in MainActor.assumeIsolated { GraphState.shared.onDown(a.first) }; return .undefined }
        let move = JSClosure { a in MainActor.assumeIsolated { GraphState.shared.onMove(a.first) }; return .undefined }
        let up = JSClosure { a in MainActor.assumeIsolated { GraphState.shared.onUp(a.first) }; return .undefined }
        let wheel = JSClosure { a in MainActor.assumeIsolated { GraphState.shared.onWheel(a.first) }; return .undefined }
        pointerClosures = [down, move, up, wheel]
        canvas.onpointerdown = .object(down)
        canvas.onpointermove = .object(move)
        canvas.onpointerup = .object(up)
        // Non-passive wheel listener so we can preventDefault (stop the page from scrolling/zooming).
        let opts = JSObject.global.Object.function!.new()
        opts.passive = .boolean(false)
        _ = canvas.addEventListener!("wheel", wheel.jsValue, opts)
    }

    // Pointer X relative to the canvas, in screen space (robust to page transforms / devicePixelRatio,
    // unlike `offsetX`). Uses clientX − the canvas's bounding rect.
    private func pointerX(_ e: JSValue) -> Double {
        guard let canvasEl else { return 0 }
        let left = canvasEl.getBoundingClientRect!().left.number ?? 0
        return (e.clientX.number ?? 0) - left
    }

    private func onDown(_ event: JSValue?) {
        guard let e = event else { return }
        dragging = true
        dragStartX = pointerX(e)
        dragStartAngle = angle
        dragMoved = 0
    }

    private func onMove(_ event: JSValue?) {
        guard dragging, let e = event else { return }
        let dx = pointerX(e) - dragStartX
        dragMoved = max(dragMoved, abs(dx))
        angle = dragStartAngle + dx * 0.012   // drag horizontally to spin the graph
    }

    private func onUp(_ event: JSValue?) {
        dragging = false
        if dragMoved < 6, let e = event { handleTap(e) }   // a tap, not a drag → select
    }

    /// Two-finger scroll pans; pinch (ctrl-scroll, the macOS trackpad convention) zooms about the
    /// cursor. The pan/zoom live in the camera uniform, so labels/edges/nodes move together.
    private func onWheel(_ event: JSValue?) {
        guard let e = event, let canvasEl else { return }
        _ = e.preventDefault()
        let rect = canvasEl.getBoundingClientRect!()
        let width = rect.width.number ?? 1, height = rect.height.number ?? 1
        let dy = e.deltaY.number ?? 0
        let dx = e.deltaX.number ?? 0
        let ctrl = e.ctrlKey.boolean ?? false
        if ctrl {
            // Zoom about the cursor: keep its post-rotation screen point fixed.
            let px = (e.clientX.number ?? 0) - (rect.left.number ?? 0)
            let py = (e.clientY.number ?? 0) - (rect.top.number ?? 0)
            let psx = ((px / width) * 2 - 1) / aspect      // cursor in pan-space coords
            let psy = 1 - (py / height) * 2
            let newZoom = min(max(zoom * exp(-dy * 0.01), 0.35), 6.0)
            let r = newZoom / zoom
            panX = psx - (psx - panX) * r
            panY = psy - (psy - panY) * r
            zoom = newZoom
        } else {
            panX += -dx * ((2.0 / aspect) / width)
            panY += dy * (2.0 / height)
        }
    }

    private func handleTap(_ event: JSValue) {
        guard let canvasEl else { return }
        let rect = canvasEl.getBoundingClientRect!()
        let left = rect.left.number ?? 0, top = rect.top.number ?? 0
        let width = rect.width.number ?? 1, height = rect.height.number ?? 1
        let px = (event.clientX.number ?? 0) - left
        let py = (event.clientY.number ?? 0) - top
        // Screen → world: undo aspect, pan, zoom, then rotation (the inverse of clip()).
        let psx = ((px / width) * 2 - 1) / aspect
        let psy = 1 - (py / height) * 2
        let prx = (psx - panX) / zoom, pry = (psy - panY) / zoom
        let c = cos(-angle), s = sin(-angle)
        let lx = prx * c - pry * s
        let ly = prx * s + pry * c
        let halfW = nodeHalfW, halfH = nodeHalfH
        var hit: Int?
        for i in centers.indices where abs(lx - centers[i].x) <= halfW * 1.2 && abs(ly - centers[i].y) <= halfH * 1.35 {
            hit = i; break
        }
        selected = hit
        if let h = hit { onSelect?(names[h]) }
    }

    // MARK: Frame

    private func frame(_ time: Double) {
        guard let dev = device, let ctx = context, let nodePipe, let edgePipe, let arrowPipe,
              let bindGroup, let uniform, let quad, let nodeInst, let edgeInst, let arrowInst,
              let textInst, let msaaView else { return }

        simulate()   // advance the force-directed layout
        for i in activation.indices { activation[i] += (target[i] - activation[i]) * 0.16 }

        // Rebuild edge + arrow instances from the (moving) node positions.
        var eData: [Double] = []
        var aData: [Double] = []
        for (s, d) in edges {
            let cs = centers[s], cd = centers[d]
            let dx = cd.x - cs.x, dy = cd.y - cs.y
            let len = max((dx * dx + dy * dy).squareRoot(), 1e-5)
            let ux = dx / len, uy = dy / len
            let ax = cs.x + ux * nodeR, ay = cs.y + uy * nodeR
            let bx = cd.x - ux * nodeR, by = cd.y - uy * nodeR
            eData += [ax, ay, bx, by, 0.5, 0.48, 0.62, 0.006]
            aData += [bx, by, ux, uy, 0.7, 0.68, 0.82, arrowSize]
        }
        if !edges.isEmpty {
            dev.queue.writeBuffer(edgeInst, bufferOffset: 0, data: f32(eData))
            dev.queue.writeBuffer(arrowInst, bufferOffset: 0, data: f32(aData))
        }

        // Node instances.
        var nData: [Double] = []
        for i in names.indices {
            let (r, g, b) = color(i)
            nData += [centers[i].x, centers[i].y, nodeR * 1.8, nodeR * 1.8, r, g, b, activation[i], selected == i ? 1.0 : 0.0]
        }
        dev.queue.writeBuffer(nodeInst, bufferOffset: 0, data: f32(nData))

        // Text: lay out each label as distance-field glyph quads, centred on its node.
        glyphCount = 0
        if textPipe != nil, let font = fontAtlas {
            var tData: [Double] = []
            let vCenter = (font.ascender + font.descender) * 0.5   // em offset to vertically centre
            for i in names.indices {
                var em = labelEm
                let w = font.measure(names[i])
                let maxW = nodeHalfW * 1.7              // keep the label inside the node box
                if w * em > maxW { em = maxW / w }
                let originX = centers[i].x - w * em * 0.5
                let baselineY = centers[i].y - vCenter * em
                let n = font.appendQuads(names[i], into: &tData, originX: originX, baselineY: baselineY,
                                         em: em, color: (1, 1, 1, 1))
                glyphCount += UInt32(n)
            }
            if glyphCount > 0 { dev.queue.writeBuffer(textInst, bufferOffset: 0, data: f32(tData)) }
        }

        // Camera uniform: a = (time, aspect, rotation, zoom), b = (panX, panY, _, _).
        dev.queue.writeBuffer(uniform, bufferOffset: 0, data: f32([time, aspect, angle, zoom, panX, panY, 0, 0]))

        let enc = dev.createCommandEncoder()
        let pass = enc.beginRenderPass(descriptor: GPURenderPassDescriptor(colorAttachments: [
            GPURenderPassColorAttachment(view: msaaView, resolveTarget: ctx.getCurrentTexture().createView(),
                clearValue: GPUColor(r: 0.05, g: 0.05, b: 0.08, a: 1), loadOp: .clear, storeOp: .store)]))
        if !edges.isEmpty {
            pass.setPipeline(edgePipe); pass.setBindGroup(0, bindGroup: bindGroup)
            pass.setVertexBuffer(0, buffer: quad); pass.setVertexBuffer(1, buffer: edgeInst)
            pass.draw(vertexCount: 6, instanceCount: UInt32(edges.count))
            pass.setPipeline(arrowPipe); pass.setBindGroup(0, bindGroup: bindGroup)
            pass.setVertexBuffer(0, buffer: arrowInst)
            pass.draw(vertexCount: 3, instanceCount: UInt32(edges.count))
        }
        pass.setPipeline(nodePipe); pass.setBindGroup(0, bindGroup: bindGroup)
        pass.setVertexBuffer(0, buffer: quad); pass.setVertexBuffer(1, buffer: nodeInst)
        pass.draw(vertexCount: 6, instanceCount: UInt32(names.count))
        if let textPipe, let textBindGroup, glyphCount > 0 {
            pass.setPipeline(textPipe)
            pass.setBindGroup(0, bindGroup: bindGroup)
            pass.setBindGroup(1, bindGroup: textBindGroup)
            pass.setVertexBuffer(0, buffer: quad); pass.setVertexBuffer(1, buffer: textInst)
            pass.draw(vertexCount: 6, instanceCount: glyphCount)
        }
        pass.end()
        dev.queue.submit([enc.finish()])

        if let loop = frameLoop { _ = JSObject.global.requestAnimationFrame.function!(loop.jsValue) }
    }

    // MARK: WGSL

    static let wgsl = """
    struct Cam { a: vec4f, b: vec4f };           // a=(time, aspect H/W, rotation, zoom), b=(panX, panY, _, _)
    @group(0) @binding(0) var<uniform> u: Cam;

    fn clip(p: vec2f) -> vec4f {
        let c = cos(u.a.z);
        let s = sin(u.a.z);
        let r = vec2f(p.x * c - p.y * s, p.x * s + p.y * c);   // rotate in square world space
        let z = r * u.a.w + u.b.xy;                            // zoom about origin, then pan
        return vec4f(z.x * u.a.y, z.y, 0.0, 1.0);              // aspect-fit to the canvas
    }

    fn sdRoundBox(p: vec2f, b: vec2f, r: f32) -> f32 {
        let q = abs(p) - b + vec2f(r);
        return min(max(q.x, q.y), 0.0) + length(max(q, vec2f(0.0))) - r;
    }

    struct Solid { @builtin(position) pos: vec4f, @location(0) color: vec3f };

    @vertex
    fn vs_edge(@location(0) corner: vec2f, @location(1) a: vec2f, @location(2) b: vec2f,
               @location(3) color: vec3f, @location(4) thick: f32) -> Solid {
        let t = corner.x * 0.5 + 0.5;
        let along = mix(a, b, t);
        let dir = normalize(b - a);
        let perp = vec2f(-dir.y, dir.x);
        var o: Solid; o.pos = clip(along + perp * corner.y * thick); o.color = color; return o;
    }

    @vertex
    fn vs_arrow(@builtin(vertex_index) vi: u32, @location(0) tip: vec2f, @location(1) dir: vec2f,
                @location(2) color: vec3f, @location(3) size: f32) -> Solid {
        let perp = vec2f(-dir.y, dir.x);
        var p = tip;
        if (vi == 1u) { p = tip - dir * size * 1.9 + perp * size; }
        else if (vi == 2u) { p = tip - dir * size * 1.9 - perp * size; }
        var o: Solid; o.pos = clip(p); o.color = color; return o;
    }

    @fragment
    fn fs_solid(@location(0) color: vec3f) -> @location(0) vec4f { return vec4f(color, 1.0); }

    struct NodeOut {
        @builtin(position) pos: vec4f,
        @location(0) color: vec3f,
        @location(1) uv: vec2f,
        @location(2) sel: f32,
        @location(3) act: f32,
    };

    @vertex
    fn vs_node(@location(0) corner: vec2f, @location(1) center: vec2f, @location(2) halfSize: vec2f,
               @location(3) color: vec3f, @location(4) activation: f32, @location(5) selected: f32) -> NodeOut {
        let pulse = 1.0 + 0.06 * sin(u.a.x * 4.0) * activation;
        var o: NodeOut;
        o.pos = clip(center + corner * halfSize * pulse);
        let dim = mix(0.5, 1.0, activation);
        let glow = 1.0 + 0.45 * (0.5 + 0.5 * sin(u.a.x * 4.0)) * activation;
        o.color = color * dim * glow;
        o.uv = corner; o.sel = selected; o.act = activation;
        return o;
    }

    // Straight-alpha "over" compositing (top over bottom).
    fn over(ct: vec3f, at: f32, cb: vec3f, ab: f32) -> vec4f {
        let a = at + ab * (1.0 - at);
        if (a <= 0.0001) { return vec4f(0.0); }
        return vec4f((ct * at + cb * ab * (1.0 - at)) / a, a);
    }

    @fragment
    fn fs_node(@location(0) color: vec3f, @location(1) uv: vec2f, @location(2) sel: f32, @location(3) act: f32) -> @location(0) vec4f {
        let bExt = vec2f(0.66, 0.46);                 // rounded-rectangle half-extents (uv space)
        let rad = 0.26;                               // corner radius
        let d = sdRoundBox(uv, bExt, rad);            // signed distance to the rounded rect
        let aa = max(fwidth(d), 0.0008) * 1.3;        // screen-space anti-alias width

        // Soft drop shadow, offset downward.
        let sd = sdRoundBox(uv - vec2f(0.0, 0.16), bExt, rad);
        let shadowA = (1.0 - smoothstep(0.0, 0.22, sd)) * 0.5;

        // Outer coloured glow on the active node (cheap fake bloom).
        let glowA = (1.0 - smoothstep(0.0, 0.40, d)) * act * 0.6;

        // Filled disc with a subtle vertical gradient.
        let fill = 1.0 - smoothstep(0.0, aa, d);
        let base = color * (1.0 + 0.18 * uv.y);

        // White selection ring just inside the rim.
        let ring = (1.0 - smoothstep(0.0, aa + 0.015, abs(d + 0.05))) * sel;
        let surface = mix(base, vec3f(1.0), ring);

        // Composite back-to-front: shadow, then glow, then the disc.
        let g = over(color, glowA, vec3f(0.0), shadowA);
        return over(surface, fill, g.rgb, g.a);
    }

    // --- Distance-field text (SDF or MSDF), one instanced quad per glyph ---
    @group(1) @binding(0) var samp: sampler;
    @group(1) @binding(1) var atlas: texture_2d<f32>;
    struct TParams { pxRange: f32, mode: f32, outline: f32, _pad: f32 };
    @group(1) @binding(2) var<uniform> tp: TParams;

    struct GlyphOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f, @location(1) color: vec4f };

    @vertex
    fn vs_glyph(@location(0) corner: vec2f, @location(1) wmin: vec2f, @location(2) wmax: vec2f,
                @location(3) uvmin: vec2f, @location(4) uvmax: vec2f, @location(5) color: vec4f) -> GlyphOut {
        let cu = corner * 0.5 + vec2f(0.5);                 // 0..1 across the quad
        var o: GlyphOut;
        o.pos = clip(mix(wmin, wmax, cu));
        // plane y is up; atlas v is down → flip v.
        o.uv = vec2f(mix(uvmin.x, uvmax.x, cu.x), mix(uvmin.y, uvmax.y, 1.0 - cu.y));
        o.color = color;
        return o;
    }

    fn median3(a: f32, b: f32, c: f32) -> f32 { return max(min(a, b), min(max(a, b), c)); }

    @fragment
    fn fs_glyph(@location(0) uv: vec2f, @location(1) color: vec4f) -> @location(0) vec4f {
        let s = textureSample(atlas, samp, uv);
        var sd: f32;
        if (tp.mode > 0.5) { sd = median3(s.r, s.g, s.b); } else { sd = s.r; }

        // Anti-alias in screen space: scale the distance range by texels-per-pixel (Chlumsky's method).
        let dims = vec2f(textureDimensions(atlas, 0));
        let unitRange = vec2f(tp.pxRange) / dims;
        let screenTexSize = vec2f(1.0) / fwidth(uv);
        let spr = max(0.5 * dot(unitRange, screenTexSize), 1.0);

        let fillA = clamp((sd - 0.5) * spr + 0.5, 0.0, 1.0);
        // Dark outline a touch outside the glyph edge, for contrast on any background.
        let outA = clamp((sd - (0.5 - tp.outline)) * spr + 0.5, 0.0, 1.0);
        let rgb = mix(vec3f(0.0), color.rgb, fillA);
        let a = max(fillA, outA * 0.9) * color.a;
        return vec4f(rgb, a);
    }
    """
}
