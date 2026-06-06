import Testing
@testable import SwiftXState

private struct AlwaysContext: Sendable, Equatable, Codable {
    var ready: Bool
}

@Suite("Always transitions")
struct AlwaysTests {
    @Test("always transition runs after entering a state")
    func alwaysOnEntry() {
        let machine = createMachine(MachineConfig(
            initial: "checking",
            context: AlwaysContext(ready: false),
            states: [
                "checking": StateNodeConfig(
                    always: [
                        TransitionConfig(
                            target: "done",
                            guard: .inline { $0.context.ready }
                        ),
                    ]
                ),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let (snapshot, _) = SwiftXState.initialTransition(
            machine,
            context: AlwaysContext(ready: true)
        )

        #expect(snapshot.matches("done"))
        #expect(snapshot.status == .done)
    }

    @Test("always transition runs after guarded event transition")
    func alwaysAfterEvent() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: AlwaysContext(ready: false),
            states: [
                "idle": StateNodeConfig(on: [
                    "PREPARE": .single(TransitionConfig(
                        target: "checking",
                        actions: [assign { ctx, _ in ctx.ready = true }]
                    )),
                ]),
                "checking": StateNodeConfig(
                    always: [
                        TransitionConfig(
                            target: "done",
                            guard: .inline { $0.context.ready }
                        ),
                    ]
                ),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let (initial, _) = SwiftXState.initialTransition(machine)
        let (next, _) = SwiftXState.transition(machine, snapshot: initial, event: Event("PREPARE"))

        #expect(next.matches("done"))
        #expect(next.context.ready)
    }

    @Test("always transition is skipped when guard fails")
    func alwaysGuardBlocks() {
        let machine = createMachine(MachineConfig(
            initial: "checking",
            context: AlwaysContext(ready: false),
            states: [
                "checking": StateNodeConfig(
                    always: [
                        TransitionConfig(
                            target: "done",
                            guard: .inline { $0.context.ready }
                        ),
                    ]
                ),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let (snapshot, _) = SwiftXState.initialTransition(machine)

        #expect(snapshot.matches("checking"))
        #expect(snapshot.status == .active)
    }
}