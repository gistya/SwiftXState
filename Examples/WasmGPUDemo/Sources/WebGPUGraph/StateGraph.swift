import Foundation
import JavaScriptKit
import JavaScriptEventLoop
import SwiftWebGPU

/// A reusable, GPU-accelerated state-machine graph renderer for the browser (Swift → WebAssembly →
/// WebGPU). Point it at an XState-style machine-definition JSON and a `<canvas>` element; it parses
/// the states/transitions into a graph, lays them on a ring, and renders interactive, animated
/// nodes + edges + arrowheads. The active state is highlighted (eased animation + pulse); tapping a
/// node fires `onSelect`.
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
    public static func start(
        canvasElementId: String,
        definitionJSON: String,
        onSelect: ((String) -> Void)? = nil
    ) async {
        await GraphState.shared.start(canvasElementId: canvasElementId, definitionJSON: definitionJSON, onSelect: onSelect)
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
    private var activation: [Double] = []   // eased current
    private var target: [Double] = []       // 0/1 goal
    private var selected: Int?
    private var onSelect: ((String) -> Void)?

    // GPU
    private var device: GPUDevice?
    private var context: GPUCanvasContext?
    private var edgePipe: GPURenderPipeline?
    private var arrowPipe: GPURenderPipeline?
    private var nodePipe: GPURenderPipeline?
    private var bindGroup: GPUBindGroup?
    private var uniform: GPUBuffer?
    private var quad: GPUBuffer?
    private var nodeInst: GPUBuffer?
    private var edgeInst: GPUBuffer?
    private var arrowInst: GPUBuffer?
    private var aspect = 1.0

    private var frameLoop: JSClosure?
    private var clickClosure: JSClosure?

    private let ringR = 0.72
    private let nodeR = 0.12
    private let arrowSize = 0.045

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

    // MARK: Layout + colours

    private func layout() {
        let n = max(names.count, 1)
        centers = names.indices.map { i in
            let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
            return (cos(a) * ringR, sin(a) * ringR)
        }
        activation = Array(repeating: 0, count: names.count)
        target = Array(repeating: 0, count: names.count)
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

    func start(canvasElementId: String, definitionJSON: String, onSelect: ((String) -> Void)?) async {
        self.onSelect = onSelect
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

        // Explicit shared layout so one bind group is compatible with all three pipelines
        // (auto layouts are per-pipeline and would not be interchangeable).
        let bgl = dev.createBindGroupLayout(descriptor: GPUBindGroupLayoutDescriptor(entries: [
            GPUBindGroupLayoutEntry(binding: 0, visibility: [.vertex, .fragment],
                                    buffer: GPUBufferBindingLayout(type: .uniform))]))
        let pipeLayout = dev.createPipelineLayout(descriptor: GPUPipelineLayoutDescriptor(bindGroupLayouts: [bgl]))

        edgePipe = dev.createRenderPipeline(descriptor: GPURenderPipelineDescriptor(
            vertex: GPUVertexState(module: module, entryPoint: "vs_edge", buffers: [quadL, edgeL]),
            fragment: target0(format), layout: .layout(pipeLayout)))
        arrowPipe = dev.createRenderPipeline(descriptor: GPURenderPipelineDescriptor(
            vertex: GPUVertexState(module: module, entryPoint: "vs_arrow", buffers: [arrowL]),
            fragment: target0(format), layout: .layout(pipeLayout)))
        nodePipe = dev.createRenderPipeline(descriptor: GPURenderPipelineDescriptor(
            vertex: GPUVertexState(module: module, entryPoint: "vs_node", buffers: [quadL, nodeL]),
            fragment: GPUFragmentState(module: module, entryPoint: "fs_node", targets: [GPUColorTargetState(format: format)]),
            layout: .layout(pipeLayout)))

        quad = dev.createBuffer(descriptor: GPUBufferDescriptor(size: 48, usage: [.vertex, .copyDst]))
        dev.queue.writeBuffer(quad!, bufferOffset: 0, data: f32([-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1]))
        nodeInst = dev.createBuffer(descriptor: GPUBufferDescriptor(size: UInt64(max(names.count, 1) * 36), usage: [.vertex, .copyDst]))
        edgeInst = dev.createBuffer(descriptor: GPUBufferDescriptor(size: UInt64(max(edges.count, 1) * 32), usage: [.vertex, .copyDst]))
        arrowInst = dev.createBuffer(descriptor: GPUBufferDescriptor(size: UInt64(max(edges.count, 1) * 32), usage: [.vertex, .copyDst]))
        uniform = dev.createBuffer(descriptor: GPUBufferDescriptor(size: 16, usage: [.uniform, .copyDst]))
        bindGroup = dev.createBindGroup(descriptor: GPUBindGroupDescriptor(
            layout: bgl,
            entries: [GPUBindGroupEntry(binding: 0, resource: .buffer(uniform!))]))

        // Static edge + arrow instances (geometry doesn't change).
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
            dev.queue.writeBuffer(edgeInst!, bufferOffset: 0, data: f32(eData))
            dev.queue.writeBuffer(arrowInst!, bufferOffset: 0, data: f32(aData))
        }

        device = dev; context = ctx
        placeLabels()
        installClick(canvas)

        frameLoop = JSClosure { args in
            let ms = args.first?.number ?? 0
            MainActor.assumeIsolated { GraphState.shared.frame(ms / 1000.0) }
            return .undefined
        }
        _ = JSObject.global.requestAnimationFrame.function!(frameLoop!.jsValue)
    }

    private func placeLabels() {
        let document = JSObject.global.document
        let stage = document.getElementById("stage").object!
        for (i, name) in names.enumerated() {
            let leftPct = (centers[i].x * aspect * 0.5 + 0.5) * 100.0
            let topPct = (1.0 - (centers[i].y * 0.5 + 0.5)) * 100.0
            let label = document.createElement("div")
            label.innerText = .string(name)
            label.style = .string(
                "position:absolute;left:\(leftPct)%;top:\(topPct)%;transform:translate(-50%,-50%);"
                + "color:#fff;font:600 13px system-ui;pointer-events:none;text-shadow:0 1px 4px rgba(0,0,0,.85)")
            _ = stage.appendChild!(label)
        }
    }

    private func installClick(_ canvas: JSObject) {
        let closure = JSClosure { args in
            MainActor.assumeIsolated {
                guard let event = args.first else { return }
                GraphState.shared.handleClick(event)
            }
            return .undefined
        }
        clickClosure = closure
        canvas.onclick = .object(closure)
    }

    private func handleClick(_ event: JSValue) {
        let ox = event.offsetX.number ?? 0
        let oy = event.offsetY.number ?? 0
        let el = JSObject.global.document.getElementById("gpu")
        let cw = el.clientWidth.number ?? 1
        let chh = el.clientHeight.number ?? 1
        // To world space (undo the aspect compression on x).
        let ndcX = (ox / cw) * 2 - 1
        let ndcY = 1 - (oy / chh) * 2
        let wx = ndcX / aspect
        let wy = ndcY
        var hit: Int?
        for i in centers.indices {
            let dx = wx - centers[i].x, dy = wy - centers[i].y
            if (dx * dx + dy * dy).squareRoot() <= nodeR * 1.2 { hit = i; break }
        }
        selected = hit
        if let h = hit { onSelect?(names[h]) }
    }

    // MARK: Frame

    private func frame(_ time: Double) {
        guard let dev = device, let ctx = context, let nodePipe, let edgePipe, let arrowPipe,
              let bindGroup, let uniform, let quad, let nodeInst, let edgeInst, let arrowInst else { return }

        // Ease activation toward target.
        for i in activation.indices { activation[i] += (target[i] - activation[i]) * 0.16 }

        // Rebuild node instances (cheap).
        var nData: [Double] = []
        for i in names.indices {
            let (r, g, b) = color(i)
            nData += [centers[i].x, centers[i].y, nodeR, nodeR, r, g, b, activation[i], selected == i ? 1.0 : 0.0]
        }
        dev.queue.writeBuffer(nodeInst, bufferOffset: 0, data: f32(nData))
        dev.queue.writeBuffer(uniform, bufferOffset: 0, data: f32([time, aspect, 0, 0]))

        let enc = dev.createCommandEncoder()
        let pass = enc.beginRenderPass(descriptor: GPURenderPassDescriptor(colorAttachments: [
            GPURenderPassColorAttachment(view: ctx.getCurrentTexture().createView(),
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
        pass.end()
        dev.queue.submit([enc.finish()])

        if let loop = frameLoop { _ = JSObject.global.requestAnimationFrame.function!(loop.jsValue) }
    }

    // MARK: WGSL

    static let wgsl = """
    @group(0) @binding(0) var<uniform> u: vec4f;  // x = time, y = aspect (H/W)

    fn clip(p: vec2f) -> vec4f { return vec4f(p.x * u.y, p.y, 0.0, 1.0); }

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
    };

    @vertex
    fn vs_node(@location(0) corner: vec2f, @location(1) center: vec2f, @location(2) halfSize: vec2f,
               @location(3) color: vec3f, @location(4) activation: f32, @location(5) selected: f32) -> NodeOut {
        let pulse = 1.0 + 0.10 * sin(u.x * 4.0) * activation;
        var o: NodeOut;
        o.pos = clip(center + corner * halfSize * pulse);
        let dim = mix(0.45, 1.0, activation);
        let glow = 1.0 + 0.5 * (0.5 + 0.5 * sin(u.x * 4.0)) * activation;
        o.color = color * dim * glow;
        o.uv = corner; o.sel = selected;
        return o;
    }

    @fragment
    fn fs_node(@location(0) color: vec3f, @location(1) uv: vec2f, @location(2) sel: f32) -> @location(0) vec4f {
        let d = length(uv);
        if (d > 1.0) { discard; }
        if (sel > 0.5 && d > 0.78) { return vec4f(1.0, 1.0, 1.0, 1.0); }
        return vec4f(color, 1.0);
    }
    """
}
