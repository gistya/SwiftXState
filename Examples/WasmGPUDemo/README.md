# SwiftXState on the GPU (WebAssembly + WebGPU)

Experimental. A state-machine graph view drawn on the GPU in the browser, all from Swift compiled to
WebAssembly.

Two parts:

- `WebGPUGraph` — a reusable toolkit. Give it an XState-style machine-definition JSON and a
  `<canvas>` id. It parses the states and transitions, lays them out, and draws interactive nodes,
  edges, arrowheads, and text labels, with an active-state highlight and tap-to-select. The camera
  does drag-to-rotate, two-finger pan, and pinch-zoom. It only depends on JavaScriptKit and
  swift-webgpu, not on SwiftXState, so any state-machine JSON works.
- `WasmGPUDemo` — a small demo that builds a SwiftXState media-player machine and points the toolkit
  at its `definitionJSON()`.

The path is SwiftXState → WebAssembly → JavaScriptKit → WebGPU (Metal/Vulkan/D3D underneath). The
WGSL shaders are Swift strings; the pipelines, buffers, bind groups, and render loop all run from
Swift.

## How do I use it?

```swift
import WebGPUGraph

await StateGraph.start(
    canvasElementId: "gpu",
    definitionJSON: try machine.definitionJSON(),
    textMode: .msdf           // .msdf (embedded atlas, default) or .sdf (self-contained, no asset)
) { tappedNodeName in
    print("tapped", tappedNodeName)
}

// after each transition, tell it the active state and the highlight eases over:
StateGraph.setActiveState(actor.snapshot.value.description)
```

The page needs a `<canvas id="gpu">` and a `#status` element. Your app owns the machine and the
buttons; the toolkit owns the drawing, labels included (no HTML overlay).

## What's in it?

- The graph comes straight from the machine. The definition JSON is decoded and its states and `on`
  targets become nodes and edges. Swap the machine and the graph follows.
- Layout is force-directed: nodes repel, edges pull like springs, and a little gravity keeps it
  centered. It runs every frame and settles on its own.
- Four instanced pipelines share one uniform: edges, arrowheads (procedural triangles, no vertex
  buffer), nodes, and text.
- Nodes are SDF rounded rectangles with a drop shadow, a selection ring, and a glow on the active
  node. 4× MSAA cleans up the edge and arrow geometry.
- The camera lives in the shader. One `clip()` helper rotates, zooms, pans, and aspect-fits, so
  nodes, edges, arrows, and labels all move together. Drag to rotate, two-finger scroll to pan,
  pinch (or ctrl-scroll) to zoom about the cursor.
- Tap-to-select inverts that camera transform and box-tests the nodes. The picked node gets a ring
  and fires `onSelect`.
- The active highlight eases toward its target each frame, so it glides between states.

Almost no JavaScript. A wasm app can't reach WebGPU, the DOM, or events without a JS bridge — that's
the platform, and JavaScriptKit is the bridge. The only hand-written JS is one line:
`import { init } from "./bundle.js"; init();`. Everything else is Swift.

## Text labels

Labels are distance-field text, laid out per glyph by a small engine (`TextEngine.swift`) against a
font atlas of per-glyph metrics. One instanced quad per glyph, drawn through a distance-field shader
with screen-space anti-aliasing. They stay crisp at any zoom, sit inside their nodes, and move with
the camera.

Two atlas providers, picked with `textMode:` (or `?text=sdf`):

- MSDF (default). A multi-channel atlas generated offline from the font outline
  (`tools/make-msdf.mjs`, embedded as `assets/msdf.{png,json}`). Corners stay sharp at any
  magnification and there's nothing to compute at load, just a texture decode. The shader reads the
  edge with `median(rgb)`.
- Runtime SDF (`?text=sdf`, and the automatic fallback if the atlas is missing). A single-channel
  field built entirely in Swift at load: rasterize each glyph, run an exact Euclidean distance
  transform (Felzenszwalb & Huttenlocher), pack into an `r8unorm` atlas. No asset, no tool, fully
  self-contained, but it costs about half a second on startup for ASCII. The shader reads `.r`.

Same pipeline either way; a `mode` uniform picks which.

## Requirements

- A WebGPU browser: Chrome/Edge 113+, Safari 18+, or Firefox 141+. Without WebGPU the status line
  says so and nothing draws.
- A swift.org WebAssembly SDK (`swift sdk list`); the build defaults to `swift-6.3.2-RELEASE_wasm`.
  Node and npm for bundling.

## How do I build it?

```sh
./build.sh                 # → self-contained ./site
npx --yes serve site       # open the printed URL in a WebGPU browser
```

Use `build.sh` (the PackageToJS `js` plugin), not a bare `swift build --swift-sdk …wasm` — that one
tries to build JavaScriptKit's BridgeJS tool for the wasm triple and fails.

The wasm is big (~62 MB; it bundles SwiftXState, Foundation, and the WebGPU bindings). Install
binaryen (`brew install binaryen`) so `wasm-opt` can shrink it, and serve it gzipped.

## Things that bit me

A few WebGPU traps, written down so the next person (or me) doesn't lose an afternoon.

- `active` is a reserved WGSL keyword. Using it as an attribute name fails compilation, which shows
  up as a black canvas with no error thrown. Renamed it to `selected`. When a canvas goes
  unexpectedly black, wrap the calls in `device.pushErrorScope('validation')` / `popErrorScope()` to
  get the real message.
- Auto pipeline layouts are per-pipeline. A bind group from `pipelineA.getBindGroupLayout(0)` won't
  work on `pipelineB` even if the binding looks identical, and you get another silent black canvas.
  With several pipelines sharing a uniform, make an explicit `GPUBindGroupLayout` + `GPUPipelineLayout`
  and pass it to all of them.
- Instance stride has to match the bytes you write. A `float32x2,float32x2,float32x3,f32,f32` instance
  is 36 bytes; setting `arrayStride: 40` misaligns everything after the first instance.
- GPU and JS objects aren't `Sendable`, so the rAF and click closures (which must be `@Sendable`)
  can't capture them. Keep the objects in `@MainActor` globals and touch them inside
  `MainActor.assumeIsolated { … }`; browser callbacks run on the one main thread anyway.
- The text pipeline adds a second bind group (`@group(1)`: sampler, atlas, params uniform); `@group(0)`
  stays the shared camera uniform. The atlas v-axis is flipped relative to plane space, so flip `v`
  in the glyph vertex shader. The runtime-SDF upload uses `writeTexture` into `r8unorm`, whose
  `bytesPerRow` must be 256-aligned, so the atlas width is fixed at 256. Reading canvas pixels for
  the distance transform: wrap `imageData.data` as a `JSTypedArray<JSUInt8Clamped>` and use
  `withUnsafeBytes` for one bulk copy — per-pixel reads across the bridge are far too slow.
- The `wheel` listener has to be non-passive (`addEventListener('wheel', cb, { passive: false })`) or
  `preventDefault()` is ignored and the page scrolls instead. `ctrlKey` on a wheel event is the macOS
  trackpad pinch.
- `performance.now()` throws "Illegal invocation" if you call it detached. Call it on the object:
  `JSObject.global.performance.object!.now!()`.

## A note on performance (SDF vs MSDF)

Roughly:

- Drawing costs the same either way: one texture sample plus the same AA math. MSDF adds a `median3`
  and samples rgba8 instead of r8, which isn't measurable for text.
- Startup differs. Runtime SDF runs the distance transform in Swift on every load (~470–600 ms for
  ASCII, single-threaded, on un-optimized wasm). MSDF does that work offline, so load is just a
  texture decode plus a ~90 KB download.
- Memory differs the other way. The SDF atlas is single-channel (~128 KB); the MSDF atlas is rgba8
  (~1 MB).

So MSDF wins on startup and corner sharpness, SDF wins on size and needing no asset. MSDF is the
default. Caching the SDF in IndexedDB would even out the startup cost if you ever want to drop the
asset.

## What's next?

- GPU UI panes on top of the text engine: popover inspector drawers (actor state, JSON trees, event
  feed) as SDF rounded-rect panels with `TextEngine` labels.
- Curved or orthogonal edge routing.
- Nested and parallel states, and `always`/`after`, in the parser.

## Regenerating the MSDF atlas

```sh
cd tools && npm install && node make-msdf.mjs   # → assets/msdf.{png,json}
```

Roboto Bold (Apache-2.0); the atlas is a redistributable derivative. The committed
`assets/msdf.{png,json}` is the default. If it goes missing the app falls back to runtime SDF, and
`?text=sdf` forces SDF anyway.
