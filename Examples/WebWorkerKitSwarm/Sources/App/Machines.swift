import SwiftXState
import SwiftXStateDistributed   // MachineHost / MachineReport

// Two machines with Codable contexts — the payloads that cross the worker boundary.
// Authored with the config API; a DSL-authored machine (Plan D) would work identically
// since both produce a `ResolvedMachine` (see the workers).

// MARK: - Counter — guards on self-transitions (context-only), bounded to [0, 10].

struct CounterContext: Codable, Sendable, Equatable {
    var value: Int = 0
}

func makeCounter() -> MachineHostSpec<CounterContext> {
    let inc = assign { (c: inout CounterContext, _: ActionArgs<CounterContext>) in c.value += 1 }
    let dec = assign { (c: inout CounterContext, _: ActionArgs<CounterContext>) in c.value -= 1 }
    let zero = assign { (c: inout CounterContext, _: ActionArgs<CounterContext>) in c.value = 0 }
    let machine = createMachine(MachineConfig<CounterContext>(
        id: "counter",
        initial: "counting",
        context: CounterContext(),
        states: [
            "counting": StateNodeConfig(on: [
                // Bounded guards: `+` is illegal at 10, `−` illegal at 0 — the worker reports
                // which are `enabled`, so the buttons disable themselves without duplicating the guards.
                "INC": .single(TransitionConfig(target: nil, guard: .inline { $0.context.value < 10 }, actions: [inc])),
                "DEC": .single(TransitionConfig(target: nil, guard: .inline { $0.context.value > 0 }, actions: [dec])),
                "RESET": .single(TransitionConfig(target: nil, actions: [zero])),
            ])
        ]
    ))
    return MachineHostSpec(machine: machine, events: ["INC", "DEC", "RESET"])
}

// MARK: - Traffic light — real state transitions, plus a state-conditional pedestrian request.

struct TrafficContext: Codable, Sendable, Equatable {
    var cycles: Int = 0   // full red→green→yellow→red laps completed
    var peds: Int = 0     // pedestrian WALK requests granted (only legal on red)
}

func makeTrafficLight() -> MachineHostSpec<TrafficContext> {
    let lap = assign { (c: inout TrafficContext, _: ActionArgs<TrafficContext>) in c.cycles += 1 }
    let walk = assign { (c: inout TrafficContext, _: ActionArgs<TrafficContext>) in c.peds += 1 }
    let machine = createMachine(MachineConfig<TrafficContext>(
        id: "trafficLight",
        initial: "red",
        context: TrafficContext(),
        states: [
            // WALK exists only on `red`, so `enabled` lists it only while red is active — the
            // pedestrian button lights up exactly when it's legal, driven by the machine's shape.
            "red": StateNodeConfig(on: [
                "NEXT": .target("green"),
                "WALK": .single(TransitionConfig(target: nil, actions: [walk])),
            ]),
            "green": StateNodeConfig(on: ["NEXT": .target("yellow")]),
            "yellow": StateNodeConfig(on: [
                "NEXT": .single(TransitionConfig(target: "red", actions: [lap])),
            ]),
        ]
    ))
    return MachineHostSpec(machine: machine, events: ["NEXT", "WALK"])
}

// MARK: - Pairs a resolved machine with its event vocabulary for `MachineHost`.

struct MachineHostSpec<Context: Codable & Sendable & Equatable> {
    let machine: ResolvedMachine<Context>
    let events: [String]
}

extension MachineHost {
    /// Build a host from a `(machine, events)` spec.
    convenience init(_ spec: MachineHostSpec<Context>) {
        self.init(spec.machine, events: spec.events)
    }
}
