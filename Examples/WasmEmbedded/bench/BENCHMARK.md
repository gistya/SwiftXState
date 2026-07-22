# SwiftXState (Embedded wasm) vs XState v6 — transition throughput

An objective, checksum-verified comparison of **state transitions per second** between
an Embedded-Swift SwiftXState machine (compiled to WebAssembly) and an equivalent
XState v6 machine (JS, built from the local `~/dev/3rdParty/xstate` checkout at the
current commit), running in the **same Node/V8 process**.

## Metric

**Sustained transitions/second with a 1 KB context.** One transition = one event that
evaluates a guard, runs a context-updating action, and changes state. The context is
`{ counter: Int32, data: Int32[256] }` = **1024 bytes**, and every transition produces
a *new* context (immutable/CoW copy of the whole array) — so the 1 KB is actually
touched each time, which is the point of the metric.

## The identical machine (both engines)

- Two states `a ⇄ b`, one event `PING`.
- A trivial guard (`counter >= 0`) is evaluated on every `PING`.
- Each **entry** action bumps `counter` and writes `data[counter % 256] = counter`
  (in XState v6 the `assign` creator is gone; context updates are entry/exit actions
  that return `{ context }`, so the Swift side mirrors that with entry-action assigns).
- After init + N events, `counter == N + 1` and the two engines must reach an
  **identical checksum** (`counter + Σ data`). The harness refuses to report timing
  unless the checksums match.

## Fairness rules

- **No per-step boundary crossing.** Swift loops entirely inside wasm (`benchRun`
  export); XState loops entirely in JS. The host times one call per engine. This
  isolates *engine* throughput from JS↔wasm marshaling (see caveats).
- **Isolated processes.** Each engine runs in its own `node` child process with a
  raised heap, so one engine's allocation/GC pressure can't skew another's timing.
- **Warmup + median of 7 rounds.** Reported as transitions/sec (median and best).
- **Equal-work gate.** Engines that ran the same N must produce the same checksum.

## Results

`node bench.mjs 2000000 7` · Node v26 · Apple Silicon · SwiftXState core built with
`swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a`, Embedded, `-wmo`, `--strip-all`.

| engine | iters | transitions/sec (median) | ns/txn | memory |
|---|--:|--:|--:|---|
| **SwiftXState `step` (Embedded wasm)** | 2,000,000 | **~303,000** | ~3,300 | O(1) |
| XState `actor.send()` (real-world) | 2,000,000 | ~283,000 | ~3,530 | O(1) |
| XState `transition()` (pure) \* | 100,000 | ~119,000 | ~8,400 | **O(n)** |
| XState `getNextSnapshot()` (pure) \* | 100,000 | ~121,000 | ~8,230 | **O(n)** |

Checksum @ 2,000,000: `513967617` — `swift == actor` ✓ (equal work verified).

**Headline:** on the realistic, O(1) paths the two engines are **neck-and-neck** —
SwiftXState is **~1.1× faster** than XState's actor (run-to-run jitter puts it in the
1.05–1.15× band). Both spend ~3.3–3.5 µs per transition, dominated by allocating and
copying the 1 KB context and building a new snapshot.

\* **XState's pure functional API retains O(n) memory** in alpha.21 — throughput
*degrades* as the heap fills (105k t/s @ 100k → 72k @ 300k) and OOMs before 1M even
with a 4 GB heap. It's capped at 100k and measured at its most favorable size; even so
SwiftXState's pure `step` is ~2.5× faster. The actor path does not have this problem.

## Size — the other half of the story

| artifact | raw | gzip |
|---|--:|--:|
| SwiftXState Embedded wasm (whole demo module) | 766 KB | 217 KB |
| XState v6 core (esbuild `--minify`) | 94 KB | 31 KB |

XState minified is **12.3%** of the wasm raw size, **14.1%** gzipped. (If you compare
gzipped-XState to raw-wasm you get ~4% — that's mixing units.) The wasm floor is the
Swift Embedded runtime + SwiftXState core + Unicode tables; it also includes the five
demo machines and the JSON query engine, so a bench-only module would be somewhat
smaller — but not close to XState's.

**Takeaway:** raw transition speed is a wash (SwiftXState marginally ahead). The real
trade is **size**: XState is ~7–8× smaller. SwiftXState-as-wasm makes sense when you
want one engine shared across Swift + web, or Swift-native context types — not to make
web transitions faster.

## Caveats (read before quoting a number)

- **Engine vs boundary.** These numbers measure the engine loop with no per-event
  JS↔wasm crossing. A web app that drives SwiftXState **one event at a time from JS**
  pays a marshaling tax per event (in this demo, the JSON `query` ABI: serialize +
  UTF-8 + alloc + parse), which XState — being native JS — does not. For chatty
  single-event workloads that tax can erase the engine's lead; for logic that batches
  inside Swift, the wasm lead stands. A minimal int-ABI boundary would be far cheaper
  than this demo's JSON ABI.
- AOT wasm (no JIT) vs V8 JIT — both "as deployed."
- The machine is deliberately tiny (2 states) to isolate per-transition cost; deep/
  parallel machines would shift both engines.

## Reproduce

```sh
./build-xstate.sh                 # bundle local XState core (needs ~/dev/3rdParty/xstate)
(cd .. && ./build.sh)             # build the Embedded wasm (needs the 07-11 toolchain+SDK)
node bench.mjs 2000000 7          # run it
```
