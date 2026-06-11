# SwiftXState on the GPU · WebAssembly · WebGPU

**Experimental.** An interactive state-machine **graph editor view**, rendered on the **GPU** in the
browser, entirely from Swift compiled to WebAssembly. It ships as two pieces:

- **`WebGPUGraph`** — a *reusable toolkit*. Hand it an XState-style machine-definition JSON and a
  `<canvas>` id; it parses the states/transitions, lays them on a ring, and renders interactive,
  animated **nodes + edges + arrowheads** with an active-state highlight and tap-to-select. It
  depends only on JavaScriptKit + swift-webgpu — **not** on SwiftXState — so it works with any
  state-machine JSON.
- **`WasmGPUDemo`** — a thin demo that builds a SwiftXState media-player machine and points the
  toolkit at its `definitionJSON()`.

The chain is **SwiftXState → WebAssembly → JavaScriptKit → WebGPU** (Metal / Vulkan / D3D under the
hood). WGSL shaders are authored as Swift strings; the pipelines, buffers, bind groups, and
`requestAnimationFrame` loop are all driven from Swift.

## Using the toolkit

```swift
import WebGPUGraph

await StateGraph.start(
    canvasElementId: "gpu",
    definitionJSON: try machine.definitionJSON()
) { tappedNodeName in
    print("tapped", tappedNodeName)
}

// after each transition, tell it the active state — the highlight eases smoothly:
StateGraph.setActiveState(actor.snapshot.value.description)
```

The page needs `<canvas id="gpu">` inside `<div id="stage">` (for the node labels) and a `#status`
element. The app owns the machine and the event buttons; the toolkit owns the rendering.

## What it demonstrates

- **Graph from the machine** — the definition JSON is decoded and its states + `on` targets become
  nodes + edges. Swap in any machine and the graph follows.
- **Three instanced pipelines** sharing one uniform/bind-group layout: **edges** (quads stretched
  between node boundaries), **arrowheads** (procedural triangles via `@builtin(vertex_index)`, no
  vertex buffer), and **nodes** (circles via fragment `discard` outside the radius).
- **Aspect handled in the shader** — geometry lives in a square world space; a `clip()` helper
  applies the canvas aspect, so all CPU-side math (layout, edge offsets, hit-testing) stays isotropic.
- **Eased active-state animation** — each node has an `activation` value that eases toward its target
  every frame, so the highlight glides between states and the active node pulses.
- **Tap-to-select** — a canvas click is converted to world space and hit-tested against node circles;
  the picked node gets a white ring and fires `onSelect`.

## Requirements

- A **WebGPU-capable browser**: Chrome / Edge 113+, Safari 18+, or Firefox 141+. (No WebGPU → the
  status line says so and nothing renders.)
- A swift.org **WebAssembly SDK** (`swift sdk list`); the build defaults to
  `swift-6.3.2-RELEASE_wasm`. Node.js + npm for bundling.

## Build & run

```sh
./build.sh                 # → self-contained ./site
npx --yes serve site       # open the printed URL in a WebGPU browser
```

> Build via `build.sh` (the PackageToJS `js` plugin), **not** a bare `swift build --swift-sdk …wasm`
> — the latter tries to compile JavaScriptKit's BridgeJS build-tool for the wasm triple and fails.

The wasm is large (~62 MB — it bundles SwiftXState + Foundation + the WebGPU bindings); install
`binaryen` (`brew install binaryen`) so `wasm-opt` shrinks it, and serve gzipped.

## Notes / gotchas (learned the hard way)

- **WGSL reserved keywords.** `active` is reserved in WGSL — using it as an attribute name makes the
  shader fail to compile, which yields an *invalid pipeline → discarded command buffer → black
  canvas* with **no thrown error**. We renamed it `selected`. When a WebGPU canvas is unexpectedly
  black, wrap pipeline/encoder calls in `device.pushErrorScope('validation')` / `popErrorScope()`
  (or replicate the setup in plain JS) to surface the real validation message.
- **Auto layouts are per-pipeline.** A bind group created from `pipelineA.getBindGroupLayout(0)` is
  **not** compatible with `pipelineB`, even if the binding is structurally identical — another silent
  black canvas. With multiple pipelines sharing a uniform, create an **explicit**
  `GPUBindGroupLayout` + `GPUPipelineLayout` and pass `layout: .layout(...)` to all of them.
- **Instance buffer stride must match the bytes you write.** A `float32x2,float32x2,float32x3,f32,f32`
  instance is 36 bytes; setting `arrayStride: 40` (but writing 36) misaligns every instance after the
  first → giant/garbled geometry. Stride = exact packed size.
- **Sendable + JS callbacks.** GPU/JS objects aren't `Sendable`, so the `requestAnimationFrame` and
  click closures (which must be `@Sendable`) can't capture them. We keep the GPU objects in
  `@MainActor` globals and touch them inside `MainActor.assumeIsolated { … }` — valid because
  browser callbacks run on the single main thread.
- **swift-webgpu API** was read from source (the README doesn't cover buffers/bind groups):
  `requestAdapter()` is non-throwing and returns an optional; `requestDevice()` throws;
  `draw(vertexCount:instanceCount:)`; auto bind-group layout via `pipeline.getBindGroupLayout(0)`.
- **Labels** are HTML overlays positioned as percentages over the canvas (GPU draws the nodes, the
  DOM draws the text) — GPU text would need a glyph atlas.

## Where this could go

Nodes, edges, and a layout from `definitionJSON()` are working. Natural next steps toward a real
browser-side, GPU-accelerated alternative to the SceneKit `SwiftXStateGraph` view:

- a **view/projection-matrix uniform** for pan/zoom (the uniform plumbing is already here);
- **arrowheads** and curved/orthogonal edge routing;
- **tap-picking** (read which node was clicked from its screen-space bounds);
- a **force-directed layout** instead of the ring;
- handling nested/parallel states and `always`/`after` transitions in the parser.
