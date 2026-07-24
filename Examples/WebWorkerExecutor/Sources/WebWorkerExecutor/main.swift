import JavaScriptKit
import JavaScriptEventLoop
import SwiftXState

// Runs in the browser (SharedArrayBuffer + Web Workers). Measures serial vs concurrent
// wall time for N CPU-bound units, twice: raw Swift concurrency, and SwiftXState async
// Actors — both with `executorPreference: WebWorkerTaskExecutor`. Results go to the page
// and the console.

@inline(never)
func spin(_ iters: Int, _ seed: UInt64) -> UInt64 {
    var x = seed | 1
    var i = 0
    while i < iters { x = x &* 6364136223846793005 &+ 1442695040888963407; i &+= 1 }
    return x
}
func ms(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1_000_000_000_000_000.0
}
func verdict(_ s: Double) -> String { s > 1.7 ? "MULTI-THREADED (parallel)" : "single-threaded (serial)" }
@inline(__always) func seedFor(_ i: Int) -> UInt64 { UInt64(i) &* 0x9E3779B97F4A7C15 &+ 1 }

struct SpinCtx: Sendable, Equatable { var acc: UInt64 = 0 }

func makeSpinMachine() -> ResolvedMachine<SpinCtx> {
    createMachine(MachineConfig<SpinCtx>(
        id: "spin", initial: "idle", context: SpinCtx(),
        states: [
            "idle": StateNodeConfig(on: [
                "GO": .single(TransitionConfig(target: nil, actions: [
                    assign { (c: inout SpinCtx, _: ActionArgs<SpinCtx>) in c.acc = spin(ITERS, c.acc &+ 1) }
                ]))
            ])
        ]
    ))
}

let N = 6
let ITERS = 60_000_000

nonisolated(unsafe) var out = ""
nonisolated(unsafe) var outEl: JSObject?
func log(_ s: String) {
    out += s + "\n"
    print(s)
    outEl?.textContent = .string(out)
}

func runProbe() async {
    let clock = ContinuousClock()
    var sink: UInt64 = 0
    sink &+= spin(ITERS, 42) // warmup

    let executor: WebWorkerTaskExecutor
    do {
        executor = try await WebWorkerTaskExecutor(numberOfThreads: N)
    } catch {
        log("WebWorkerTaskExecutor init failed: \(error)")
        return
    }
    log("WebWorkerTaskExecutor: \(executor.numberOfThreads) worker threads\n")

    // Warm the pool — the first parallel use pays worker spawn + module instantiation.
    await withTaskGroup(of: Void.self) { g in
        for _ in 0..<N { g.addTask(executorPreference: executor) { _ = spin(3_000_000, 9) } }
    }

    // ── Level 1: raw Swift concurrency ──────────────────────────────────────
    let s0 = clock.now
    for i in 0..<N { sink &+= spin(ITERS, seedFor(i)) }
    let seq1 = clock.now - s0
    let p0 = clock.now
    await withTaskGroup(of: UInt64.self) { g in
        for i in 0..<N { g.addTask(executorPreference: executor) { spin(ITERS, seedFor(i)) } }
        for await r in g { sink &+= r }
    }
    let par1 = clock.now - p0
    log("== Swift concurrency: withTaskGroup(executorPreference:), \(N) CPU tasks ==")
    log("   sequential: \(ms(seq1)) ms")
    log("   parallel:   \(ms(par1)) ms")
    log("   speedup:    \(ms(seq1) / ms(par1))x  ->  \(verdict(ms(seq1) / ms(par1)))\n")

    // ── Level 2: SwiftXState async Actors ───────────────────────────────────
    let machine = makeSpinMachine()
    var actors: [Actor<MachineLogic<SpinCtx>>] = []
    for _ in 0..<N { actors.append(await createActor(machine).start()) }

    let as0 = clock.now
    for a in actors { await a.send(Event("GO")) }
    let seq2 = clock.now - as0

    let ap0 = clock.now
    await withTaskGroup(of: Void.self) { g in
        for a in actors { g.addTask(executorPreference: executor) { await a.send(Event("GO")) } }
    }
    let par2 = clock.now - ap0
    log("== SwiftXState async Actor: \(N) actors, spin inside an assign action ==")
    log("   serial sends:     \(ms(seq2)) ms")
    log("   concurrent sends: \(ms(par2)) ms")
    log("   speedup:          \(ms(seq2) / ms(par2))x  ->  \(verdict(ms(seq2) / ms(par2)))")

    executor.terminate()
    log("\nsink=\(sink)")
}

JavaScriptEventLoop.installGlobalExecutor()
// Seed the page, then kick off the probe on the (now installed) global executor.
if let doc = JSObject.global.document.object,
   let pre = doc.createElement!("pre").object {
    pre.id = "out"
    pre.textContent = "booting…"
    if let body = doc.body.object { _ = body.appendChild!(pre) }
    outEl = pre
}
Task { await runProbe() }
