import Testing
@testable import SwiftXState

private struct TransitionCounterContext: Sendable, Equatable {
    var count: Int
    var step: Int
}

@Suite("fromTransition and fromObservable")
struct TransitionObservableTests {
    @Test("fromTransition receives events and updates context")
    func transitionInvoke() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "running",
            context: TransitionCounterContext(count: 0, step: 0),
            states: [
                "running": StateNodeConfig(
                    on: [
                        "TICK": .single(TransitionConfig(actions: [
                            sendTo("counter", Event("INCREMENT")),
                        ])),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "counter",
                            src: fromTransition(
                                { state, event, _ in
                                    if event.type == "INCREMENT" {
                                        return TransitionCounterContext(
                                            count: state.count + state.step,
                                            step: state.step
                                        )
                                    }
                                    return state
                                },
                                initialContext: { input in
                                    TransitionCounterContext(
                                        count: 0,
                                        step: input?.get(Int.self) ?? 1
                                    )
                                }
                            ),
                            input: { _ in SendableValue(5) }
                        ),
                    ]
                ),
            ]
        ))

        let actor = createActor(parentMachine).start()
        actor.send(Event("TICK"))
        actor.send(Event("TICK"))

        let child = actor.childActor(id: "counter")
        child?.send(Event("INCREMENT"))

        #expect(child != nil)
        #expect(actor.snapshot.matches("running"))
    }

    @Test("fromTransition onSnapshot syncs child context")
    func transitionOnSnapshot() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "running",
            context: TransitionCounterContext(count: 0, step: 0),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "counter",
                            src: fromTransition(
                                { state, event, _ in
                                    if event.type == "INCREMENT" {
                                        return TransitionCounterContext(count: state.count + 1, step: state.step)
                                    }
                                    return state
                                },
                                initialContext: TransitionCounterContext(count: 0, step: 1)
                            ),
                            onSnapshot: .single(TransitionConfig(
                                actions: [assign { ctx, args in
                                    if let event = args.event as? SnapshotActorEvent,
                                       let value = event.snapshot.value,
                                       value.contains("count: 3") {
                                        ctx.count = 3
                                    }
                                }]
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let actor = createActor(parentMachine).start()

        for _ in 0..<3 {
            actor.childActor(id: "counter")?.send(Event("INCREMENT"))
        }

        await actor.waitForSnapshot { $0.context.count == 3 }

        #expect(actor.snapshot.context.count == 3)
    }

    @Test("fromObservable emits values and completes with onDone")
    func observableOnDone() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "running",
            context: TransitionCounterContext(count: 0, step: 0),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "stream",
                            src: fromObservable { _ in
                                SequenceSubscribable(values: [1, 2, 3], intervalMs: 5)
                            },
                            onDone: .single(TransitionConfig(
                                target: "finished",
                                actions: [assign { ctx, args in
                                    if let event = args.event as? DoneActorEvent,
                                       let value = event.output?.get(Int.self) {
                                        ctx.count = value
                                    }
                                }]
                            ))
                        ),
                    ]
                ),
                "finished": StateNodeConfig(type: .final),
            ]
        ))

        let actor = createActor(parentMachine).start()
        await actor.waitForSnapshot { $0.matches("finished") }

        #expect(actor.snapshot.matches("finished"))
        #expect(actor.snapshot.context.count == 3)
        #expect(actor.snapshot.status == .done)
    }

    @Test("fromObservable reports errors with onError")
    func observableOnError() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "running",
            context: TransitionCounterContext(count: 0, step: 0),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "stream",
                            src: fromObservable { _ in
                                AnySubscribable<Int> { _, onError, _ in
                                    onError?("stream failed")
                                    return Subscription {}
                                }
                            },
                            onError: .single(TransitionConfig(
                                target: "failed",
                                actions: [assign { ctx, args in
                                    if let event = args.event as? ErrorActorEvent {
                                        ctx.step = event.error.count
                                    }
                                }]
                            ))
                        ),
                    ]
                ),
                "failed": StateNodeConfig(type: .final),
            ]
        ))

        let actor = createActor(parentMachine).start()
        await actor.waitForSnapshot { $0.matches("failed") }

        #expect(actor.snapshot.matches("failed"))
        #expect(actor.snapshot.context.step == "stream failed".count)
    }

    @Test("fromObservable ignores sent events")
    func observableIgnoresEvents() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "running",
            context: EmptyContext(),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "stream",
                            src: fromObservable { _ in
                                SequenceSubscribable(values: [42], intervalMs: 5)
                            },
                            onDone: .to("finished")
                        ),
                    ]
                ),
                "finished": StateNodeConfig(type: .final),
            ]
        ))

        let actor = createActor(parentMachine).start()
        actor.childActor(id: "stream")?.send(Event("IGNORED"))
        await actor.waitForSnapshot { $0.matches("finished") }

        #expect(actor.snapshot.matches("finished"))
    }

    @Test("named fromTransition via setup")
    func namedTransitionActor() async {
        let parentMachine = setup(
            actors: [
                "counter": ActorLogicEntry(transition: TransitionActorLogicBox(
                    TransitionActorLogic(
                        transition: { state, event, _ in
                            if event.type == "INCREMENT" {
                                return TransitionCounterContext(count: state.count + 1, step: state.step)
                            }
                            return state
                        },
                        resolveInitialContext: { _ in
                            TransitionCounterContext(count: 0, step: 1)
                        }
                    )
                )),
            ]
        ).createMachine(MachineConfig(
            initial: "running",
            context: TransitionCounterContext(count: 0, step: 0),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "counter",
                            src: .named("counter"),
                            onSnapshot: .single(TransitionConfig(
                                actions: [assign { ctx, args in
                                    if let event = args.event as? SnapshotActorEvent,
                                       let value = event.snapshot.value,
                                       value.contains("count: 2") {
                                        ctx.count = 2
                                    }
                                }]
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let actor = createActor(parentMachine).start()
        actor.childActor(id: "counter")?.send(Event("INCREMENT"))
        actor.childActor(id: "counter")?.send(Event("INCREMENT"))

        await actor.waitForSnapshot { $0.context.count == 2 }

        #expect(actor.snapshot.context.count == 2)
    }
}