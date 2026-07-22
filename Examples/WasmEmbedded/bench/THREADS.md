# Does the wasm "threads" SDK help SwiftXState on Embedded Swift?

Short answer: **no — and it can't be built anyway.** But you *can* get near-linear
multicore scaling a different way. Details below.

## 1. `wasip1-threads-embedded` doesn't build

Building `Examples/WasmEmbedded` with
`DEVELOPMENT-SNAPSHOT-2026-07-11-a-wasm32-unknown-wasip1-threads-embedded` fails at:

```
error: could not find module 'Swift' for target 'wasm32-unknown-wasip1-threads';
found: wasm32-unknown-wasip1, wasm64-unknown-none-wasm, wasm32-unknown-none-wasm
```

The compiler *did* enable the thread flags (`-matomics -mbulk-memory -mthread-model
posix -pthread -ftls-model=local-exec`), so the destination is wired for threads — but
the SDK's **Embedded** `Swift.swiftmodule` only ships three triples:

```
embedded/Swift.swiftmodule/ : wasm32-unknown-none-wasm, wasm32-unknown-wasip1, wasm64-unknown-none-wasm
```

There is **no `wasm32-unknown-wasip1-threads` embedded stdlib**. The threads triple
exists only in the *full* (non-embedded) stdlib
(`Swift.swiftmodule/wasm32-unknown-wasip1-threads.swiftmodule` is present). The bundle
even names its embedded platform module `EmbeddedPlatformSingleThreaded`.

**Conclusion:** in this toolchain, Embedded Swift on wasm is single-threaded only.
wasm threads require the full ~7 MB stdlib (the same one the earlier non-embedded
experiments used).

## 2. Even if it built, SwiftXState wouldn't parallelize inside one module

Three independent reasons:

1. **A single machine's `step` is a sequential reducer.** There is no intra-machine
   parallelism to extract — each transition depends on the previous snapshot.
2. **SwiftXState's wasm concurrency is single-threaded by design.** `Actor` and `Clock`
   are gated `#if canImport(Dispatch)`; on wasm they fall back to an inline, lock-free,
   single-threaded queue. Even with OS threads available, the actor runtime would not
   spread work across them.
3. **Embedded Swift's concurrency executor is single-threaded** (see
   `EmbeddedPlatformSingleThreaded`). `Task` / `withTaskGroup` run cooperatively on one
   thread — no multi-core execution.

Shared linear memory between threads (the thing the threads SDK actually buys you) is
only useful if the workload shares mutable state across threads. Independent state
machines don't.

## 3. What you CAN do: independent instances across worker threads

The realistic parallelism is **many independent machines**: run N single-threaded wasm
instances (each its own linear memory) on N host worker threads. No shared memory, no
threads SDK. `parallel.mjs` measures it — each Node worker owns a wasm instance and
runs the same `benchRun` loop concurrently:

```
Node v26 · Apple M1 Max (8 performance + 2 efficiency cores) · 2,000,000 txn/worker · 1 KB context

 workers     aggregate t/s   scaling   per-worker t/s
 -------------------------------------------------------
    1              256,203     1.00×          256,203
    2              598,034     2.33×          299,017
    4            1,170,119     4.57×          292,530
    6            1,720,524     6.72×          286,754
    8            2,171,927     8.48×          271,491
   10            2,282,754     8.91×          228,275
```

Near-linear to **~8.5×** across the 8 performance cores (per-worker throughput holds
~290k), then it plateaus — the 2 efficiency cores add little, and per-worker drops as
they're pressed into service. This is exactly the shape you'd expect for
embarrassingly-parallel independent work on this CPU.

**Takeaway:** you get multicore SwiftXState throughput on Embedded wasm by sharding
independent machines across workers — which needs neither the threads SDK (unbuildable)
nor any change to SwiftXState. In a browser the same pattern is Web Workers, one wasm
instance each. Reach for shared-memory wasm threads only if you needed threads to share
*one* machine's state, which the engine's design doesn't call for.

## Reproduce

```sh
node parallel.mjs 2000000 "1,2,4,6,8,10"   # needs ../dist/WasmXStateDemo.wasm (plain SDK)
```
