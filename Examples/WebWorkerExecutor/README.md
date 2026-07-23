# WebWorkerExecutor — SwiftXState actors, genuinely multi-threaded on wasm

The follow-up that overturns the earlier verdict. `ThreadsProbe` showed the *stock*
toolchain runs Swift concurrency single-threaded on wasm (SwiftXState `Actor` = 1.19×).
This shows that with **JavaScriptKit's `WebWorkerTaskExecutor`**, the *same* SwiftXState
actors run **truly in parallel** — ~5.3× across 6 Web Worker threads — with **no change
to SwiftXState**.

## Result (Node worker_threads, Apple M1 Max, 6 threads)

```
WebWorkerTaskExecutor: 6 worker threads

== Swift concurrency: withTaskGroup(executorPreference:), 6 CPU tasks ==
   speedup: ~5.1–5.3×   ->  MULTI-THREADED

== SwiftXState async Actor: 6 actors, spin inside an assign action ==
   speedup: ~5.1–5.3×   ->  MULTI-THREADED     (serial ~45 ms → concurrent ~9 ms)
```

~85–88% parallel efficiency on 6 workers. (A tiny workload or a cold pool shows less —
warm the executor and give each task real work, as the probe does.)

## Why it works — and why *no* SwiftXState change is needed

- `WebWorkerTaskExecutor` (JavaScriptKit `JavaScriptEventLoop`) is a `TaskExecutor`
  (SE-0417) backed by `wasi_pthread` + a **Web Worker pool over SharedArrayBuffer** —
  the exact `thread-spawn` mechanism `ThreadsProbe` proved is wired.
- SwiftXState's `Actor` has a custom `ActorSerialExecutor`, **but that's
  `#if canImport(Darwin)` only**. On wasm (no Darwin) it compiles out, leaving a plain
  **default actor** — and default actors *honor the enclosing task's executor
  preference*. So:
  ```swift
  JavaScriptEventLoop.installGlobalExecutor()
  let ex = try await WebWorkerTaskExecutor(numberOfThreads: 6)
  await withTaskGroup(of: Void.self) { g in
      for a in actors { g.addTask(executorPreference: ex) { await a.send(.tick) } }
  }
  ```
  runs each actor's `send` on a real worker thread. **Parallel, unmodified.**
  (Caveat: on *Darwin* the custom serial executor would ignore the preference — this
  door is wasm-specific.)

## Trade-off vs `../WasmSwarm`

Both reach multicore throughput; different shapes:

| | WebWorkerTaskExecutor (this) | WasmSwarm (independent instances) |
|---|---|---|
| model | one wasm instance, **shared memory**, N worker threads | N wasm instances, isolated memory, N host workers |
| stdlib | full (~14 MB) + threads SDK | Embedded (~330 KB) |
| runtime | JavaScriptKit threads (browser SAB+COOP/COEP, or node worker_threads) | plain Web Workers / worker_threads |
| shares state | yes (real shared memory) | no (copies across postMessage) |
| SwiftXState change | none | none |

Use this when actors need to **share memory/state** across threads; use the swarm when
independent shards + a tiny module are what you want.

## Build & run

Requires the `swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a` toolchain, its full-stdlib
`wasip1-threads` SDK, Node, and network (JavaScriptKit 0.56.1 + the JS runtime dep).

```sh
./build.sh
(cd Bundle && node run-node.mjs)     # headless, prints the speedups
```

Notes that cost time, so they're written down:
- **`--build-system native`** is mandatory — the default Xcode build backend does a
  per-module relocatable prelink (`-r`) that `wasm-ld` refuses alongside
  `--shared-memory`.
- **JavaScriptKit 0.53 does *not* compile** under the 6.5-dev snapshot (its experimental
  `Clock.enqueue` scheduling SPI drifted); **0.56.1 does**.
- The probe's DOM output is guarded, so it runs headless in Node (stdout→console) and in
  a browser (writes to a `<pre>`). In a browser you must serve `Bundle/` with
  `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp`
  (SharedArrayBuffer requirement).
