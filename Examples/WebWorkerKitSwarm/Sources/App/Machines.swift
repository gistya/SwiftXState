import SwiftXState

// A concrete machine with a Codable context — the payload that crosses the worker
// boundary. Authored with the config API; a DSL-authored machine (Plan D) would work
// identically since both produce a `ResolvedMachine` (see CounterWorker).
struct CounterContext: Codable, Sendable, Equatable {
    var value: Int = 0
}

func makeCounter() -> ResolvedMachine<CounterContext> {
    let inc = assign { (c: inout CounterContext, _: ActionArgs<CounterContext>) in c.value += 1 }
    let dec = assign { (c: inout CounterContext, _: ActionArgs<CounterContext>) in c.value -= 1 }
    let zero = assign { (c: inout CounterContext, _: ActionArgs<CounterContext>) in c.value = 0 }
    return createMachine(MachineConfig<CounterContext>(
        id: "counter",
        initial: "counting",
        context: CounterContext(),
        states: [
            "counting": StateNodeConfig(on: [
                "INC": .single(TransitionConfig(target: nil, guard: .inline { $0.context.value < 10 }, actions: [inc])),
                "DEC": .single(TransitionConfig(target: nil, guard: .inline { $0.context.value > 0 }, actions: [dec])),
                "RESET": .single(TransitionConfig(target: nil, actions: [zero])),
            ])
        ]
    ))
}
