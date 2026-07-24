import SwiftXState

// The device "firmware": a battery-aware behavior state machine. Every device in
// the swarm runs an independent instance of THIS machine — same code a real embedded
// build would flash to hardware, here stepped thousands of times per frame in wasm.
//
//   patrol → (DETECT beacon) → seek → (ARRIVE) → sample → (battery full) → patrol
//   any    → (INTERFERE)      → evade → (timer) → patrol
//   any    → (battery critical) → sleep → (battery recovered) → patrol
//
// Battery + the evade timer live in context and are mutated by assign actions; the
// battery/timer thresholds are `.inline` guards. Beacon detection (DETECT/ARRIVE/
// LOSE) and the global INTERFERE are events the shard engine sends based on sensing
// — guards never sense, so nothing here needs to downcast the event (Embedded-safe).

struct BrainContext: Sendable {
    var battery: Float = 100   // 0…100
    var evade: Int32 = 0       // ticks remaining in an evade burst
}

// State ids as seen by the renderer (kept in sync with `stateId(of:)`).
enum DeviceState {
    static let patrol: Float = 0
    static let seek: Float = 1
    static let sample: Float = 2
    static let evade: Float = 3
    static let sleep: Float = 4
}

private let critical: Float = 15   // below this → sleep
private let full: Float = 95       // sampled up to here → back to patrol
private let rested: Float = 42     // sleep wakes here
private let evadeBurst: Int32 = 45 // ticks spent scattering

func makeFirmware() -> ResolvedMachine<BrainContext> {
    let drainSlow = assign { (c: inout BrainContext, _: ActionArgs<BrainContext>) in c.battery = max(0, c.battery - 0.03) }
    let drain     = assign { (c: inout BrainContext, _: ActionArgs<BrainContext>) in c.battery = max(0, c.battery - 0.09) }
    let charge    = assign { (c: inout BrainContext, _: ActionArgs<BrainContext>) in c.battery = min(100, c.battery + 0.6) }
    let trickle   = assign { (c: inout BrainContext, _: ActionArgs<BrainContext>) in c.battery = min(100, c.battery + 0.16) }
    let startEvade = assign { (c: inout BrainContext, _: ActionArgs<BrainContext>) in c.evade = evadeBurst; c.battery = max(0, c.battery - 0.1) }
    let tickEvade = assign { (c: inout BrainContext, _: ActionArgs<BrainContext>) in c.evade -= 1; c.battery = max(0, c.battery - 0.09) }

    let lowBattery: GuardRef<BrainContext> = .inline { $0.context.battery < critical }
    let fullBattery: GuardRef<BrainContext> = .inline { $0.context.battery >= full }
    let evadeDone: GuardRef<BrainContext> = .inline { $0.context.evade <= 0 }
    let restedEnough: GuardRef<BrainContext> = .inline { $0.context.battery >= rested }

    // TICK is an eventless heartbeat: first candidate whose guard passes wins,
    // otherwise the last (guardless) candidate runs the per-state battery action.
    return createMachine(MachineConfig<BrainContext>(
        id: "firmware",
        initial: "patrol",
        context: BrainContext(),
        // Each device boots with its own battery level (passed as the actor input) so
        // the swarm desyncs instead of all draining in lockstep.
        contextFromInput: { input in
            BrainContext(battery: input?.get(Float.self) ?? 100, evade: 0)
        },
        states: [
            "patrol": StateNodeConfig(on: [
                "TICK": .multiple([
                    TransitionConfig(target: "sleep", guard: lowBattery, actions: [drainSlow]),
                    TransitionConfig(target: nil, actions: [drainSlow]),
                ]),
                "DETECT": .to("seek"),
                "INTERFERE": .single(TransitionConfig(target: "evade", actions: [startEvade])),
            ]),
            "seek": StateNodeConfig(on: [
                "TICK": .multiple([
                    TransitionConfig(target: "sleep", guard: lowBattery, actions: [drain]),
                    TransitionConfig(target: nil, actions: [drain]),
                ]),
                "ARRIVE": .to("sample"),
                "LOSE": .to("patrol"),
                "INTERFERE": .single(TransitionConfig(target: "evade", actions: [startEvade])),
            ]),
            "sample": StateNodeConfig(on: [
                "TICK": .multiple([
                    TransitionConfig(target: "patrol", guard: fullBattery, actions: [charge]),
                    TransitionConfig(target: nil, actions: [charge]),
                ]),
                "LOSE": .to("patrol"),
                "INTERFERE": .single(TransitionConfig(target: "evade", actions: [startEvade])),
            ]),
            "evade": StateNodeConfig(on: [
                "TICK": .multiple([
                    TransitionConfig(target: "patrol", guard: evadeDone),
                    TransitionConfig(target: nil, actions: [tickEvade]),
                ]),
                // A fresh interference refreshes the burst without leaving the state.
                "INTERFERE": .single(TransitionConfig(target: nil, actions: [startEvade])),
            ]),
            "sleep": StateNodeConfig(on: [
                "TICK": .multiple([
                    TransitionConfig(target: "patrol", guard: restedEnough),
                    TransitionConfig(target: nil, actions: [trickle]),
                ]),
                "INTERFERE": .single(TransitionConfig(target: "evade", actions: [startEvade])),
            ]),
        ]
    ))
}

@inline(__always)
func stateId(of snapshot: MachineSnapshot<BrainContext>) -> Float {
    guard case let .atomic(name) = snapshot.value else { return DeviceState.patrol }
    switch name {
    case "patrol": return DeviceState.patrol
    case "seek": return DeviceState.seek
    case "sample": return DeviceState.sample
    case "evade": return DeviceState.evade
    case "sleep": return DeviceState.sleep
    default: return DeviceState.patrol
    }
}
