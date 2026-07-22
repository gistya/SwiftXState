import SwiftXState

// Throughput benchmark entry point. Mirrors the XState v6 bench machine exactly so
// the two engines do identical per-transition work:
//   • context = { counter: Int32, data: [Int32] × 256 }  → 1 KB payload
//   • each entered state runs an entry action that bumps counter and writes one
//     array cell (forcing a full 1 KB copy-on-write per transition)
//   • a trivial guard is evaluated on every PING
//
// `benchRun` runs the whole step loop INSIDE wasm and returns a checksum, so the
// host times one call — no per-step JS↔wasm boundary. The checksum lets the harness
// prove both engines produced identical final context before trusting any timing.

private let benchDataCount = 256   // 256 × Int32 = 1024 bytes

struct BenchContext: Sendable {
    var counter: Int32 = 0
    var data: [Int32] = Array(repeating: 0, count: benchDataCount)
}

private func makeBenchMachine() -> ResolvedMachine<BenchContext> {
    // Increment, then write the cell indexed by the NEW counter — identical to the
    // XState updater `counter = context.counter + 1; data[counter % N] = counter`.
    let updater = assign { (c: inout BenchContext, _: ActionArgs<BenchContext>) in
        c.counter &+= 1
        c.data[Int(c.counter) % benchDataCount] = c.counter
    }
    let alwaysPass = GuardRef<BenchContext>.inline { $0.context.counter >= 0 }
    return createMachine(MachineConfig<BenchContext>(
        id: "bench",
        initial: "a",
        context: BenchContext(),
        states: [
            "a": StateNodeConfig(
                on: ["PING": .single(TransitionConfig(target: "b", guard: alwaysPass))],
                entry: [updater]
            ),
            "b": StateNodeConfig(
                on: ["PING": .single(TransitionConfig(target: "a", guard: alwaysPass))],
                entry: [updater]
            ),
        ]
    ))
}

private enum BenchState {
    // Cache the resolved machine so machine-construction cost isn't re-paid per run.
    nonisolated(unsafe) static var logic: MachineLogic<BenchContext>?
    static func machine() -> MachineLogic<BenchContext> {
        if let existing = logic { return existing }
        let created = MachineLogic(machine: makeBenchMachine())
        logic = created
        return created
    }
}

/// Run `iterations` PING transitions through the pure reducer and return a checksum
/// of the final context (counter + sum of the data array). Timed as one call by the
/// host; the initial snapshot + checksum are O(1)/O(256), negligible vs a large loop.
@_expose(wasm, "benchRun")
@_cdecl("benchRun")
func benchRun(_ iterations: Int32) -> Int64 {
    let logic = BenchState.machine()
    var snapshot = logic.initialState(input: nil)   // runs entry of state "a" → counter 1
    let ping = Event("PING")
    var i: Int32 = 0
    while i < iterations {
        snapshot = logic.step(snapshot, on: ping)
        i &+= 1
    }
    var checksum = Int64(snapshot.context.counter)
    for value in snapshot.context.data {
        checksum &+= Int64(value)
    }
    return checksum
}
