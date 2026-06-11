# SwiftXState on the GPU · WebAssembly · WebGPU

**Experimental.** A SwiftXState machine's **graph** rendered on the **GPU**, in the browser,
entirely from Swift compiled to WebAssembly. **Nodes and edges are derived from the machine's own
`definitionJSON()`** — states become instanced circles, transitions become instanced line-quads,
laid out on a ring. The **active** state (from the live snapshot) is brightened and pulses via a
time uniform. One button per event drives the actor (disabled when `snapshot.can(_:)` is false), and
the GPU re-renders the new active state.

The chain is: **SwiftXState → WebAssembly → JavaScriptKit → WebGPU** (Metal / Vulkan / D3D under
the hood). The WGSL shaders are authored as Swift strings; the render pipelines, buffers, bind
groups, and `requestAnimationFrame` loop are all driven from Swift.

## What it demonstrates

- **Graph from the machine** — `definitionJSON()` is decoded into `JSONValue`; states and their
  `on` targets become nodes + edges, laid out on a circle. Swap in any machine and the graph follows.
- **Instanced rendering, two pipelines** — one shared unit-quad + per-instance buffer
  (`center/halfSize/color/selected` for nodes, reinterpreted as `a/b/color/thickness` for edges),
  drawn with `draw(vertexCount: 6, instanceCount: N)`. Nodes are circles (fragment `discard` outside
  the radius); edges are quads stretched between node centers.
- **A uniform buffer** carrying elapsed time, updated each frame with `queue.writeBuffer`, so the
  active node pulses on the GPU.
- **Wiring to the machine** — the node instance buffer is rewritten from `actor.snapshot` whenever an
  event fires, so "which node is active" is the state machine's truth, not the renderer's.

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
