# WasmSwarmLite — a lite swarm of *communicating* SwiftXState actors

A small "signal mesh": ~24 nodes, each its **own SwiftXState machine** (`resting → firing →
refractory`), all invoked as children of one **router** machine. Unlike the other WASM demos
(where the instances are independent — the firmware swarm's devices only sense shared beacons,
the WebWorkerKit workers are fully isolated), here the instances **talk to each other** —
through SwiftXState's real actor machinery. Click a node and a wave of excitation ripples out
across the graph. One full-stdlib WASM instance, no Web Workers.

## The point: real inter-actor communication

XState has no sibling addressing — actors talk *through a shared parent*. So a node never
calls another node directly; it goes through the router, using the framework's genuine
delivery:

```
node i fires  ──sendToParent("FIRED#i")──►  router
router  ──sendTo("n\(j)", "PULSE")──►  each graph-neighbour j of i   (charge them)
```

Firing is gated to a per-frame `TICK` the router broadcasts to every child, so a charged node
only fires on the next tick — which makes excitation spread **exactly one ring per frame**, a
visible travelling wave. Refractory nodes are deaf to `PULSE`, so colliding wavefronts
annihilate — the same excitable-medium behaviour as neurons or heart tissue.

This is the only demo in the set that exercises SwiftXState's **async `Actor` + `invoke` +
`sendToParent`/`sendTo`** — the machinery the Embedded and WebWorkerKit demos had to avoid
(Embedded can't run the async actor; WebWorkerKit swaps in Codable transport).

## Files

- `Sources/App/Machines.swift` — the node machine (`makeNode`), the router (`makeRouter`,
  which programmatically builds one `invoke` + a `FIRED#i`/`STIM#i` transition per node), and
  the grid topology.
- `Sources/App/App.swift` — the driver: `createActor(router).start()`, a ~10 Hz step loop
  (`send("STEP")` each frame), a 2-D canvas renderer, and click-to-stimulate. All via
  JavaScriptKit.

## Rendering feed — a deliberate choice

The canvas is driven by the router's **own context** (`justFired: [Int]`, refilled each STEP),
not by reading each child's state from `snapshot.children`. Invoked-child snapshots are **not**
synced into the parent's `children` map unless you set `onSnapshot` on the invoke (which would
also flood the parent with a snapshot event per child transition). Reading the router's own
context is always current and far cheaper, so the renderer lights a node the moment its `FIRED`
is relayed and fades it over an afterglow window. The node FSMs remain the source of truth for
the *simulation* (their guards + refractory decide excitability); the client just projects the
`FIRED` feed for the *visual*.

## Build & run

Requires the `swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a` toolchain, its full-stdlib `wasip1`
SDK, Node, and network (JavaScriptKit + the JS runtime dep). Same PackageToJS recipe as the
sibling WebWorkerKit example.

```sh
./build.sh
(cd Bundle && python3 -m http.server 8779)   # then open http://localhost:8779/
```

Click a node (or **Stimulate centre**) to inject a wave; **Pacemaker** launches one
periodically; **Reset** clears the field.

## Notes that cost time (kept for the next person)

- The step loop uses **`setTimeout`, not `requestAnimationFrame`** — rAF is fully paused on a
  hidden/background tab, which would freeze the whole simulation.
- It runs at **~10 Hz on purpose.** A tight loop (35 cross-boundary actor sends + a full canvas
  redraw per frame) monopolises the single JS thread and starves clicks; unhurried stepping
  keeps the page interactive.
- `String.range(of:)` / `.contains(_ substring:)` need **Foundation** (not imported here) —
  use stdlib `split`/`hasPrefix` instead.
- Returning a Swift `JSPromise.async {…}` from a `JSClosure` (a debug hook we tried) faulted
  the WASM instance with an out-of-bounds memory access on this toolchain — avoid spawning
  promises/tasks from inside JS callbacks; drive async work from the long-lived startup task.
