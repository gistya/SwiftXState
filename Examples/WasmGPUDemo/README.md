# SwiftXState on the GPU · WebAssembly · WebGPU

**Experimental.** An interactive state-machine **graph editor view**, rendered on the **GPU** in the
browser, entirely from Swift compiled to WebAssembly. It ships as two pieces:

- **`WebGPUGraph`** — a *reusable toolkit*. Hand it an XState-style machine-definition JSON and a
  `<canvas>` id; it parses the states/transitions, runs a **force-directed layout**, and renders
  interactive, animated **nodes + edges + arrowheads + GPU text labels** with an active-state
  highlight and tap-to-select. A shader-based camera supports **drag-to-rotate, two-finger pan, and
  pinch-zoom**. It depends only on JavaScriptKit + swift-webgpu — **not** on SwiftXState — so it
  works with any state-machine JSON.
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
    definitionJSON: try machine.definitionJSON(),
    textMode: .msdf           // .msdf (embedded atlas, default) or .sdf (self-contained, no asset)
) { tappedNodeName in
    print("tapped", tappedNodeName)
}

// after each transition, tell it the active state — the highlight eases smoothly:
StateGraph.setActiveState(actor.snapshot.value.description)
```

The page needs `<canvas id="gpu">` and a `#status` element. The app owns the machine and the event
buttons; the toolkit owns the rendering (labels included — they're drawn on the GPU now, so no HTML
overlay is required).

## What it demonstrates

- **Graph from the machine** — the definition JSON is decoded and its states + `on` targets become
  nodes + edges. Swap in any machine and the graph follows.
- **Force-directed layout** — nodes repel, edges act as springs, and a gentle pull keeps the graph
  centred. The simulation runs each frame (cheap for a handful of states); edges, arrows and labels
  all recompute from the moving positions, so the graph settles into an organic arrangement.
- **Four instanced pipelines** sharing one uniform/bind-group layout: **edges** (quads stretched
  between node boundaries), **arrowheads** (procedural triangles via `@builtin(vertex_index)`, no
  vertex buffer), **nodes**, and **text** (glyph-atlas quads).
- **Distance-field text labels** — a small **text engine** (`TextEngine.swift`) lays each label out
  per-glyph against a font atlas of *metrics* (advance + plane bounds + UV per glyph, in em units)
  and draws one instanced quad per glyph through a screen-space-AA distance-field shader. Labels are
  resolution-independent — crisp at *any* zoom — ride *inside* their nodes, transform with the camera,
  and carry a dark contrast outline. **No HTML overlay.** Two interchangeable atlas providers (pick
  with `textMode:` / `?text=sdf`):
  - **True MSDF** (default, `MSDFFont`) — a *multi-channel* SDF atlas generated offline from the
    font's vector outline (`tools/make-msdf.mjs`, embedded as `assets/msdf.{png,json}`), so corners
    stay razor-sharp even under extreme magnification, with **no per-load compute** (just a texture
    decode). The shader reconstructs the edge with `median(rgb)`.
  - **Runtime SDF** (`SDFFont`, `?text=sdf`; also the automatic fallback if the atlas isn't served) —
    a single-channel signed distance field computed **entirely in Swift at load**: each glyph is
    rasterised to a canvas, an exact Euclidean distance transform (Felzenszwalb & Huttenlocher) turns
    it into a field, packed into an `r8unorm` atlas. No asset, no tool, no extra JS — fully
    self-contained, at the cost of a one-time ~½ s distance-transform on startup. The shader samples
    `.r`. Same pipeline as MSDF, switched by a `mode` uniform.
- **SDF rounded-rect nodes + 4× MSAA** for a polished look: nodes are drawn from a signed-distance
  field (`sdRoundBox`) with a `smoothstep`/`fwidth` anti-aliased edge, a soft **drop shadow** (the
  same SDF offset down), a **selection ring**, and a coloured **glow** on the active node (a cheap
  fake-bloom — the SDF sampled *outside* the shape). MSAA antialiases the edge/arrow geometry. All
  technique, no engine.
- **Shader camera: rotate / pan / zoom** — `clip()` rotates square world space, scales by the zoom,
  adds the pan, then aspect-fits, all from one `Cam` uniform (`a = time, aspect, rotation, zoom`;
  `b = panX, panY`). **Drag** to spin, **two-finger scroll** to pan, **pinch / ctrl-scroll** to zoom
  about the cursor (a non-passive `wheel` listener so the page doesn't scroll). Because everything is
  drawn through `clip()`, nodes, edges, arrows and labels all transform together.
- **Tap-to-select** — a tap is hit-tested by inverting the whole camera transform (undo aspect, pan,
  zoom, rotation) to land in world space, then box-testing the nodes — using `clientX` +
  `getBoundingClientRect()` (robust to page transforms/DPR, unlike `offsetX`). The picked node gets a
  white ring and fires `onSelect`.
- **Almost no JavaScript.** A browser wasm app can't reach Web APIs (WebGPU, DOM, events) without a
  JS bridge — that's the platform, and JavaScriptKit is that bridge. But the *only hand-written*
  JavaScript here is a single bootstrap line (`import { init } from "./bundle.js"; init();`).
  Everything else — graph parsing, layout, WebGPU, the render loop, drag/tap input — is Swift.
- **Aspect handled in the shader** — geometry lives in a square world space; a `clip()` helper
  applies rotation, zoom, pan and the canvas aspect, so all CPU-side math (layout, edge offsets,
  hit-testing) stays isotropic.
- **Eased active-state animation** — each node has an `activation` value that eases toward its target
  every frame, so the highlight glides between states and the active node pulses.

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
- **Distance-field text.** The text pipeline adds a **second bind group** (`@group(1)`: sampler +
  atlas + a params uniform); `@group(0)` stays the shared camera uniform, so the same uniform bind
  group is reused. The screen-space AA is Chlumsky's MSDF method: `screenPxRange = pxRange ·
  texels-per-pixel` via `fwidth(uv)`, then `alpha = clamp((sd − 0.5)·screenPxRange + 0.5)`. The
  **atlas v-axis is flipped** relative to plane space (atlas top is `v = 0`, glyph top is `+y`) —
  flip `v` in the glyph vertex shader. Runtime-SDF upload uses `writeTexture` into an `r8unorm`
  texture, so its `bytesPerRow` must be **256-aligned** (we fix the atlas width at 256); the MSDF
  atlas is a PNG decoded via `img.decode()` → `createImageBitmap` → `copyExternalImageToTexture`.
  Reading canvas pixels for the distance transform: wrap `imageData.data` as a
  `JSTypedArray<JSUInt8Clamped>` and `withUnsafeBytes` for one bulk copy — per-pixel bridge reads are
  far too slow.
- **Non-passive `wheel` listener.** `addEventListener('wheel', cb, { passive: false })` — otherwise
  `preventDefault()` is ignored and the page scrolls/zooms instead of the graph. `ctrlKey` on a wheel
  event is the macOS trackpad **pinch** signal (vs. a plain two-finger scroll).

## Where this could go

Nodes, edges, a force-directed layout, distance-field text (runtime SDF **and** true MSDF), and a
rotate/pan/zoom camera from `definitionJSON()` are working. Natural next steps toward a real
browser-side, GPU-accelerated alternative to the SceneKit `SwiftXStateGraph` view:

- **GPU UI panes** built on the text engine — popover inspector drawers (actor state, JSON trees,
  event feed) drawn as SDF rounded-rect panels with `TextEngine` labels;
- curved / orthogonal **edge routing**;
- handling nested/parallel states and `always`/`after` transitions in the parser.

### Regenerating the MSDF atlas

```sh
cd tools && npm install && node make-msdf.mjs   # → assets/msdf.{png,json}
```

Uses Roboto Bold (Apache-2.0); the generated atlas is a redistributable derivative. The committed
`assets/msdf.{png,json}` is the default text mode; if it's ever missing the app falls back to the
runtime SDF, and `?text=sdf` forces SDF regardless.
