import Testing
@testable import SwiftXState

struct CounterContext: Sendable, Equatable, Codable {
    var count: Int
}

@Suite("Transition")
struct TransitionTests {
    @Test("initialTransition captures entry actions")
    func initialTransitionCapturesActions() {
        let flag = Flag()

        let machine = setup(
            actions: [
                "increment": { _ in flag.value = true },
            ]
        ).createMachine(MachineConfig(
            initial: "idle",
            context: CounterContext(count: 0),
            states: ["idle": StateNodeConfig()],
            entry: [.named("increment")]
        ))

        let (snapshot, actions) = SwiftXState.initialTransition(machine)

        #expect(snapshot.context.count == 0)
        #expect(actions.count == 1)
        #expect(actions[0].type == "increment")
        #expect(!flag.value)
    }

    @Test("transition captures actions without executing")
    func pureTransition() {
        let flag = Flag()

        let machine = setup(
            actions: [
                "add": { _ in flag.value = true },
            ]
        ).createMachine(MachineConfig(
            initial: "idle",
            context: CounterContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "ADD": .single(TransitionConfig(actions: [.named("add")])),
                ]),
            ]
        ))

        let (initial, _) = SwiftXState.initialTransition(machine)
        let (next, actions) = SwiftXState.transition(machine, snapshot: initial, event: Event("ADD"))

        #expect(next.context.count == 0)
        #expect(actions.count == 1)
        #expect(!flag.value)
    }

    @Test("assign updates context via pure transition")
    func assignPureTransition() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: CounterContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INCREMENT": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                ]),
            ]
        ))

        let (initial, _) = SwiftXState.initialTransition(machine)
        let (next, actions) = SwiftXState.transition(machine, snapshot: initial, event: Event("INCREMENT"))
        #expect(next.context.count == 1)
        #expect(actions.count == 1)
    }

    @Test("assign property map updates Codable context")
    func assignProperties() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: CounterContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "SET": .single(TransitionConfig(
                        actions: [assign(["count": { _ in SendableValue(5) }])]
                    )),
                ]),
            ]
        ))

        let (initial, _) = SwiftXState.initialTransition(machine)
        let (next, _) = SwiftXState.transition(machine, snapshot: initial, event: Event("SET"))
        #expect(next.context.count == 5)
    }

    @Test("assign updates context via actor")
    func assignAction() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: CounterContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INCREMENT": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                ]),
            ]
        ))

        let actor = createActor(machine).start()
        actor.send(Event("INCREMENT"))
        #expect(actor.snapshot.context.count == 1)
    }
}

private final class Flag: @unchecked Sendable {
    var value = false
}