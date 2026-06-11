import Foundation
import JavaScriptKit
import JavaScriptEventLoop
import SwiftWebGPU
import SwiftXState

// Experimental: a SwiftXState machine's *graph* rendered on the GPU, from Swift via WebAssembly.
// Nodes + edges are derived from the machine's own `definitionJSON()`; nodes are instanced circles,
// edges are instanced line-quads. The active state (from the live snapshot) brightens and pulses.

JavaScriptEventLoop.installGlobalExecutor()

let canvasW = 720.0
let canvasH = 480.0
let aspect = canvasH / canvasW

// MARK: - The machine (branching, so the graph has real structure)

struct FetchCtx: Sendable, Equatable {}

let machine = createMachine(MachineConfig(
    id: "fetch",
    initial: "idle",
    context: FetchCtx(),
    states: [
        "idle": StateNodeConfig(on: ["FETCH": .to("loading")]),
        "loading": StateNodeConfig(on: ["RESOLVE": .to("success"), "REJECT": .to("failure")]),
        "failure": StateNodeConfig(on: ["RETRY": .to("loading")]),
        "success": StateNodeConfig(on: ["RESET": .to("idle")]),
    ]
))
let actor = createActor(machine).start()

// MARK: - Derive nodes + edges from definitionJSON()

func parseGraph(_ json: String) -> (nodes: [String], edges: [(Int, Int)]) {
    guard let data = json.data(using: .utf8),
          let root = try? JSONDecoder().decode(JSONValue.self, from: data),
          case let .object(rootObj) = root,
          case let .object(states)? = rootObj["states"] else { return ([], []) }

    let names = states.keys.sorted()
    let index = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })

    func targetName(_ s: String) -> String {
        var t = s
        if t.hasPrefix("#") { t.removeFirst() }
        return t.split(separator: ".").last.map(String.init) ?? t
    }

    var edges: [(Int, Int)] = []
    var seen = Set<String>()
    for name in names {
        guard case let .object(node)? = states[name], case let .object(on)? = node["on"] else { continue }
        for (_, transitions) in on {
            let elems: [JSONValue] = { if case let .array(a) = transitions { return a } else { return [transitions] } }()
            for t in elems {
                var target: String?
                if case let .string(s) = t { target = s }
                else if case let .object(o) = t, let tv = o["target"] {
                    if case let .string(s) = tv { target = s }
                    else if case let .array(a) = tv, case let .string(s)? = a.first { target = s }
                }
                guard let ts = target, let si = index[name], let di = index[targetName(ts)], si != di else { continue }
                let key = "\(si)->\(di)"
                if seen.insert(key).inserted { edges.append((si, di)) }
            }
        }
    }
    return (names, edges)
}

let graph = parseGraph((try? machine.definitionJSON()) ?? "")
let nodeNames = graph.nodes
let edges = graph.edges

// Circle layout (aspect-corrected so it's round on screen).
let nodePositions: [(Double, Double)] = nodeNames.indices.map { i in
    let theta = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(max(nodeNames.count, 1))
    return (cos(theta) * 0.72 * aspect, sin(theta) * 0.72)
}
let nodeHalf = (x: 0.13 * aspect, y: 0.13)

func palette(_ i: Int) -> (Double, Double, Double) {
    let p: [(Double, Double, Double)] = [
        (0.49, 0.36, 1.0), (0.18, 0.80, 0.55), (0.96, 0.62, 0.10),
        (0.93, 0.34, 0.45), (0.30, 0.70, 0.95),
    ]
    return p[i % p.count]
}

// MARK: - WGSL (static): edges (line-quads) + nodes (circles, active pulses).

let shaderSource = """
@group(0) @binding(0) var<uniform> u: vec4f;   // u.x = time (seconds)

// Per-instance layout is shared: vec2 @1, vec2 @2, vec3 @3, f32 @4.

struct EdgeOut { @builtin(position) pos: vec4f, @location(0) color: vec3f };

@vertex
fn vs_edge(@location(0) corner: vec2f, @location(1) a: vec2f, @location(2) b: vec2f,
           @location(3) color: vec3f, @location(4) thick: f32) -> EdgeOut {
    let t = corner.x * 0.5 + 0.5;
    let along = mix(a, b, t);
    let dir = normalize(b - a);
    let perp = vec2f(-dir.y, dir.x);
    var out: EdgeOut;
    out.pos = vec4f(along + perp * corner.y * thick, 0.0, 1.0);
    out.color = color;
    return out;
}

@fragment
fn fs_edge(@location(0) color: vec3f) -> @location(0) vec4f { return vec4f(color, 1.0); }

struct NodeOut { @builtin(position) pos: vec4f, @location(0) color: vec3f, @location(1) uv: vec2f };

@vertex
fn vs_node(@location(0) corner: vec2f, @location(1) center: vec2f, @location(2) halfSize: vec2f,
           @location(3) color: vec3f, @location(4) selected: f32) -> NodeOut {
    let pulse = 1.0 + 0.10 * sin(u.x * 4.0) * selected;
    var out: NodeOut;
    out.pos = vec4f(center + corner * halfSize * pulse, 0.0, 1.0);
    let dim = mix(0.5, 1.0, selected);
    let glow = 1.0 + 0.4 * (0.5 + 0.5 * sin(u.x * 4.0)) * selected;
    out.color = color * dim * glow;
    out.uv = corner;
    return out;
}

@fragment
fn fs_node(@location(0) color: vec3f, @location(1) uv: vec2f) -> @location(0) vec4f {
    if (length(uv) > 1.0) { discard; }
    return vec4f(color, 1.0);
}
"""

// MARK: - GPU state (MainActor globals; touched from @Sendable JS callbacks via assumeIsolated)

var gpuDevice: GPUDevice?
var gpuContext: GPUCanvasContext?
var nodePipeline: GPURenderPipeline?
var edgePipeline: GPURenderPipeline?
var gpuBindGroup: GPUBindGroup?
var gpuUniform: GPUBuffer?
var gpuQuad: GPUBuffer?
var gpuNodeInst: GPUBuffer?
var gpuEdgeInst: GPUBuffer?
var frameLoop: JSClosure?
var retained: [JSClosure] = []
var eventButtons: [(name: String, el: JSValue)] = []

@MainActor func f32(_ values: [Double]) -> JSObject {
    JSObject.global.Float32Array.function!.new(values)
}

@MainActor func setStatus(_ text: String) {
    let s = JSObject.global.document.getElementById("status")
    s.innerText = .string(text)
}

@MainActor func syncNodes() {
    guard let device = gpuDevice, let buf = gpuNodeInst else { return }
    let active = actor.snapshot.value.description
    var data: [Double] = []
    for (i, name) in nodeNames.enumerated() {
        let (cx, cy) = nodePositions[i]
        let (r, g, b) = palette(i)
        data += [cx, cy, nodeHalf.x, nodeHalf.y, r, g, b, name == active ? 1.0 : 0.0]
    }
    device.queue.writeBuffer(buf, bufferOffset: 0, data: f32(data))
    for (name, button) in eventButtons {
        let enabled = actor.snapshot.can(Event(name))
        button.disabled = .boolean(!enabled)
        button.style = .string(eventButtonStyle(enabled: enabled))
    }
    setStatus("Active state: \(active)")
}

@MainActor func eventButtonStyle(enabled: Bool) -> String {
    "margin:.25rem;padding:.45rem .9rem;font-size:.9rem;border:0;border-radius:8px;background:#7c5cff;color:#fff;cursor:pointer;"
        + (enabled ? "" : "opacity:.35;cursor:not-allowed;")
}

@MainActor func renderFrame(_ timeSeconds: Double) {
    guard let device = gpuDevice, let context = gpuContext,
          let nodePipe = nodePipeline, let edgePipe = edgePipeline,
          let bindGroup = gpuBindGroup, let uniform = gpuUniform,
          let quad = gpuQuad, let nodeInst = gpuNodeInst, let edgeInst = gpuEdgeInst else { return }

    device.queue.writeBuffer(uniform, bufferOffset: 0, data: f32([timeSeconds, 0, 0, 0]))

    let encoder = device.createCommandEncoder()
    let pass = encoder.beginRenderPass(descriptor: GPURenderPassDescriptor(
        colorAttachments: [GPURenderPassColorAttachment(
            view: context.getCurrentTexture().createView(),
            clearValue: GPUColor(r: 0.05, g: 0.05, b: 0.08, a: 1),
            loadOp: .clear, storeOp: .store
        )]
    ))
    // Edges first (under the nodes).
    if !edges.isEmpty {
        pass.setPipeline(edgePipe)
        pass.setVertexBuffer(0, buffer: quad)
        pass.setVertexBuffer(1, buffer: edgeInst)
        pass.draw(vertexCount: 6, instanceCount: UInt32(edges.count))
    }
    // Nodes on top (need the time uniform for the pulse).
    pass.setPipeline(nodePipe)
    pass.setBindGroup(0, bindGroup: bindGroup)
    pass.setVertexBuffer(0, buffer: quad)
    pass.setVertexBuffer(1, buffer: nodeInst)
    pass.draw(vertexCount: 6, instanceCount: UInt32(nodeNames.count))
    pass.end()
    device.queue.submit([encoder.finish()])
}

@MainActor func placeLabelsAndButtons() {
    let document = JSObject.global.document
    let stage = document.getElementById("stage").object!
    for (i, name) in nodeNames.enumerated() {
        let (cx, cy) = nodePositions[i]
        let leftPct = (cx * 0.5 + 0.5) * 100.0
        let topPct = (1.0 - (cy * 0.5 + 0.5)) * 100.0   // flip y for screen
        let label = document.createElement("div")
        label.innerText = .string(name)
        label.style = .string(
            "position:absolute;left:\(leftPct)%;top:\(topPct)%;transform:translate(-50%,-50%);"
            + "color:#fff;font:600 13px system-ui;pointer-events:none;text-shadow:0 1px 4px rgba(0,0,0,.8)"
        )
        _ = stage.appendChild!(label)
    }
    // One button per event the machine declares.
    let events = document.getElementById("events").object!
    for name in machine.events {
        let button = document.createElement("button")
        button.innerText = .string(name)
        let closure = JSClosure { _ in
            MainActor.assumeIsolated {
                actor.send(Event(name))
                syncNodes()
            }
            return .undefined
        }
        retained.append(closure)
        button.onclick = .object(closure)
        _ = events.appendChild!(button)
        eventButtons.append((name, button))
    }
}

// MARK: - Pipelines share one per-instance vertex layout (vec2,vec2,vec3,f32).

@MainActor func instanceLayout() -> GPUVertexBufferLayout {
    GPUVertexBufferLayout(arrayStride: 32, stepMode: .instance, attributes: [
        GPUVertexAttribute(format: .float32x2, offset: 0, shaderLocation: 1),
        GPUVertexAttribute(format: .float32x2, offset: 8, shaderLocation: 2),
        GPUVertexAttribute(format: .float32x3, offset: 16, shaderLocation: 3),
        GPUVertexAttribute(format: .float32, offset: 28, shaderLocation: 4),
    ])
}

@MainActor func quadLayout() -> GPUVertexBufferLayout {
    GPUVertexBufferLayout(arrayStride: 8, stepMode: .vertex, attributes: [
        GPUVertexAttribute(format: .float32x2, offset: 0, shaderLocation: 0),
    ])
}

@MainActor func run() async {
    guard let gpu = GPU.shared else { setStatus("WebGPU is not available in this browser."); return }
    let canvas = JSObject.global.document.getElementById("gpu").object!
    guard let adapter = await gpu.requestAdapter(),
          let device = try? await adapter.requestDevice() else {
        setStatus("Could not acquire a GPU device.")
        return
    }

    let context = GPUCanvasContext(jsObject: canvas.getContext!("webgpu").object!)
    let format = gpu.preferredCanvasFormat
    context.configure(GPUCanvasConfiguration(device: device, format: format))

    let module = device.createShaderModule(descriptor: GPUShaderModuleDescriptor(code: shaderSource))

    let nodePipe = device.createRenderPipeline(descriptor: GPURenderPipelineDescriptor(
        vertex: GPUVertexState(module: module, entryPoint: "vs_node", buffers: [quadLayout(), instanceLayout()]),
        fragment: GPUFragmentState(module: module, entryPoint: "fs_node", targets: [GPUColorTargetState(format: format)])
    ))
    let edgePipe = device.createRenderPipeline(descriptor: GPURenderPipelineDescriptor(
        vertex: GPUVertexState(module: module, entryPoint: "vs_edge", buffers: [quadLayout(), instanceLayout()]),
        fragment: GPUFragmentState(module: module, entryPoint: "fs_edge", targets: [GPUColorTargetState(format: format)])
    ))

    let quad = device.createBuffer(descriptor: GPUBufferDescriptor(size: 48, usage: [.vertex, .copyDst]))
    device.queue.writeBuffer(quad, bufferOffset: 0, data: f32([-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1]))

    let nodeInst = device.createBuffer(descriptor: GPUBufferDescriptor(size: UInt64(max(nodeNames.count, 1) * 32), usage: [.vertex, .copyDst]))
    let edgeInst = device.createBuffer(descriptor: GPUBufferDescriptor(size: UInt64(max(edges.count, 1) * 32), usage: [.vertex, .copyDst]))
    let uniform = device.createBuffer(descriptor: GPUBufferDescriptor(size: 16, usage: [.uniform, .copyDst]))
    let bindGroup = device.createBindGroup(descriptor: GPUBindGroupDescriptor(
        layout: nodePipe.getBindGroupLayout(index: 0),
        entries: [GPUBindGroupEntry(binding: 0, resource: .buffer(uniform))]
    ))

    // Edge instances are static (structure doesn't change).
    var edgeData: [Double] = []
    for (s, d) in edges {
        let (ax, ay) = nodePositions[s]
        let (bx, by) = nodePositions[d]
        edgeData += [ax, ay, bx, by, 0.45, 0.42, 0.58, 0.006]
    }
    if !edges.isEmpty { device.queue.writeBuffer(edgeInst, bufferOffset: 0, data: f32(edgeData)) }

    gpuDevice = device; gpuContext = context; nodePipeline = nodePipe; edgePipeline = edgePipe
    gpuBindGroup = bindGroup; gpuUniform = uniform; gpuQuad = quad; gpuNodeInst = nodeInst; gpuEdgeInst = edgeInst

    placeLabelsAndButtons()
    syncNodes()

    frameLoop = JSClosure { args in
        let ms = args.first?.number ?? 0
        MainActor.assumeIsolated {
            renderFrame(ms / 1000.0)
            if let loop = frameLoop {
                _ = JSObject.global.requestAnimationFrame.function!(loop.jsValue)
            }
        }
        return .undefined
    }
    _ = JSObject.global.requestAnimationFrame.function!(frameLoop!.jsValue)
}

Task { await run() }
