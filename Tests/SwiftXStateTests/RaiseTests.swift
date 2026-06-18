import Testing
@testable import SwiftXState

private struct RaiseContext: Sendable, Equatable, Codable {
    var step: Int
}

@Suite("Raise actions")
struct RaiseTests {
    @Test("raise chains transitions within a single macrostep")
    func raiseChain() {
        let machine = createMachine(MachineConfig(
            initial: "a",
            context: RaiseContext(step: 0),
            states: [
                "a": StateNodeConfig(on: [
                    "START": .single(TransitionConfig(
                        target: "b",
                        actions: [raise(Event("NEXT"))]
                    )),
                ]),
                "b": StateNodeConfig(on: [
                    "NEXT": .to("c"),
                ]),
                "c": StateNodeConfig(type: .final),
            ]
        ))

        let (initial, _) = SwiftXState.initialTransition(machine)
        let (next, actions) = SwiftXState.transition(machine, snapshot: initial, event: Event("START"))

        #expect(next.matches("c"))
        #expect(next.status == .done)
        #expect(actions.contains { $0.type == "xstate.raise" })
    }

    @Test("raise on entry runs before eventless transitions")
    func raiseOnEntry() {
        let machine = createMachine(MachineConfig(
            initial: "ready",
            context: RaiseContext(step: 0),
            states: [
                "ready": StateNodeConfig(
                    on: [
                        "GO": .single(TransitionConfig(
                            target: "done",
                            actions: [assign { ctx, _ in ctx.step = 1 }]
                        )),
                    ],
                    entry: [raise(Event("GO"))]
                ),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let (snapshot, actions) = SwiftXState.initialTransition(machine, context: RaiseContext(step: 0))

        #expect(snapshot.matches("done"))
        #expect(snapshot.context.step == 1)
        #expect(actions.contains { $0.type == "xstate.raise" })
    }

    @Test("delayed raise schedules a follow-up transition")
    func delayedRaise() async {
        let machine = setup(
            delays: [
                "short": { _ in 20 },
            ]
        ).createMachine(MachineConfig(
            initial: "idle",
            context: RaiseContext(step: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "ARM": .single(TransitionConfig(
                        actions: [raise(Event("FIRE"), delay: "short")]
                    )),
                    "FIRE": .single(TransitionConfig(
                        target: "done",
                        actions: [assign { ctx, _ in ctx.step = 1 }]
                    )),
                ]),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let reactor = createReactor(machine).start()
        #expect(reactor.snapshot.matches("idle"))

        reactor.send(Event("ARM"))
        await reactor.waitForSnapshot { $0.matches("done") }

        #expect(reactor.snapshot.matches("done"))
        #expect(reactor.snapshot.context.step == 1)
    }

    @Test("cancel prevents a delayed raise from firing")
    func cancelDelayedRaise() async {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: RaiseContext(step: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "ARM": .single(TransitionConfig(
                        actions: [raise(Event("FIRE"), delay: 100, id: "fire-timer")]
                    )),
                    "CANCEL": .single(TransitionConfig(
                        actions: [cancel("fire-timer")]
                    )),
                    "FIRE": .single(TransitionConfig(
                        target: "done",
                        actions: [assign { ctx, _ in ctx.step = 1 }]
                    )),
                ]),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let reactor = createReactor(machine).start()
        reactor.send(Event("ARM"))
        reactor.send(Event("CANCEL"))
        try? await Task.sleep(for: .milliseconds(150))

        #expect(reactor.snapshot.matches("idle"))
        #expect(reactor.snapshot.context.step == 0)
    }
}
