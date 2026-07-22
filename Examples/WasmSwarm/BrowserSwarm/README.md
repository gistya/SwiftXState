# BrowserSwarm — the all-JS (XState.js) twin, for comparison

Same swarm, same interface, **different engine**: every device is an **XState v6 actor**
running in JavaScript instead of a SwiftXState machine in Embedded wasm. Built to answer
one question — *what does the all-JS equivalent cost?* Not a knock on XState (it's the
benchmark); the point is to price out Swift-on-web against the native-JS baseline.

Only the engine differs. The Web-Worker sharding, the beacon sensing, the kinematics,
the canvas UI, and the dashboard are the same as `../` (the wasm Firmware Swarm).

## What's the same, what's ported

- **Firmware** (`swarm.mjs`): the same state graph — `patrol/seek/sample/evade/sleep`,
  battery in context, the same thresholds and guards. v6 can't update context in a
  transition action (only entry/exit), so per-tick battery changes live in each state's
  **entry** and `TICK` reenters the state; the evade countdown lives worker-side (a
  `CALM` event). Functionally equivalent per tick: one guard, one context update, an
  occasional state change.
- **Sensing + kinematics**: direct JS ports of `Swarm.swift`.
- **Stepping**: one `createActor(machine).start()` **per device**, `actor.send(...)`
  each tick — the idiomatic way to run thousands of persistent XState machines. (The
  pure `transition()` reducer would match Swift's `step` more directly but retains O(n)
  memory in alpha.21, so it can't drive a live swarm — see `../../WasmEmbedded/bench/`.)

## Head-to-head (headless, Apple M1 Max, Node v26)

Same benchmark on both sides (`bench/swarm-scale.mjs`), device-transitions/sec:

| metric | Firmware Swarm — SwiftXState → wasm | Browser Swarm — XState v6 → JS | wasm advantage |
|---|--:|--:|:--:|
| per core (1 worker) | **382,905** | 182,946 | **~2.1×** |
| aggregate (8 workers) | **2,897,305** | 631,283 | **~4.6×** |
| scaling across 8 cores | **7.57×** | 3.45× | 2.2× better |
| memory @ 24,000 devices | **4.5 MB** (~186 B/device) | **1,850 MB** (~77 KB/actor) | **~410×** |
| engine module size | 329 KB (wasm) | **94 KB** min (JS) | JS 3.5× smaller |
| toolchain to build | Swift + wasm SDK | esbuild (or none) | JS simpler |

## What the numbers say

- **Throughput:** wasm is ~2.1× faster per core, widening to ~4.6× at 8 cores.
- **Scaling is the quieter story:** wasm scales 7.6× across 8 cores; XState only 3.45×.
  Thousands of live actors generate enough allocation churn that **GC contention** caps
  the JS version well before the cores do — per-core throughput *falls* from 183k to 79k
  as workers pile on.
- **Memory is the loud one:** ~77 KB per XState actor vs ~186 bytes per wasm device —
  **~410×**. That's why this demo caps devices at 8k (24k actors already need ~1.9 GB)
  while the wasm swarm cruises at 30k+ on a few MB.
- **XState wins code size** (94 KB vs 329 KB) and needs no Swift toolchain.

Note this is a *swarm* (thousands of persistent machines). For a handful of machines the
gap nearly closes — the earlier single-machine bench had XState's actor within ~1.1× of
SwiftXState. The swarm is exactly the regime where per-actor memory and GC dominate.

Everything else — kinematics + sensing + canvas render — is identical on both sides, so
the delta is the state engine.

## Build & run

```sh
# vendor XState from the local checkout (once):
(cd ~/dev/3rdParty/xstate && npx esbuild packages/core/src/index.ts --bundle \
   --format=esm --platform=node --conditions=default \
   --outfile="$OLDPWD/vendor/xstate-core.mjs")
# (build.sh also expects vendor/xstate-core.min.mjs — same command with --minify)

./build.sh                          # → dist/index.html (self-contained)
node probe.mjs                      # behaviour + single-core rate + memory
node bench/swarm-scale.mjs 3000 150 4   # the scaling table above
```

Open `dist/index.html` (served) next to the wasm swarm at the same settings and compare.
In-app FPS is only meaningful when the tab is focused — browsers throttle background tabs.
