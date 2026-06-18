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

        let reactor = createReactor(parentMachine).start()
        reactor.send(Event("TICK"))
        reactor.send(Event("TICK"))

        let child = reactor.childReactor(id: "counter")
        child?.send(Event("INCREMENT"))

        #expect(child != nil)
        #expect(reactor.snapshot.matches("running"))
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
                                    if let event = args.event as? SnapshotReactorEvent,
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

        let reactor = createReactor(parentMachine).start()

        for _ in 0..<3 {
            reactor.childReactor(id: "counter")?.send(Event("INCREMENT"))
        }

        await reactor.waitForSnapshot { $0.context.count == 3 }

        #expect(reactor.snapshot.context.count == 3)
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
                                    if let event = args.event as? DoneReactorEvent,
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

        let reactor = createReactor(parentMachine).start()
        await reactor.waitForSnapshot { $0.matches("finished") }

        #expect(reactor.snapshot.matches("finished"))
        #expect(reactor.snapshot.context.count == 3)
        #expect(reactor.snapshot.status == .done)
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
                                    if let event = args.event as? ErrorReactorEvent {
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

        let reactor = createReactor(parentMachine).start()
        await reactor.waitForSnapshot { $0.matches("failed") }

        #expect(reactor.snapshot.matches("failed"))
        #expect(reactor.snapshot.context.step == "stream failed".count)
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

        let reactor = createReactor(parentMachine).start()
        reactor.childReactor(id: "stream")?.send(Event("IGNORED"))
        await reactor.waitForSnapshot { $0.matches("finished") }

        #expect(reactor.snapshot.matches("finished"))
    }

    @Test("named fromTransition via setup")
    func namedTransitionReactor() async {
        let parentMachine = setup(
            reactors: [
                "counter":ReactorLogicEntry(transition: TransitionReactorLogicBox(
                    TransitionReactorLogic(
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
                                    if let event = args.event as? SnapshotReactorEvent,
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

        let reactor = createReactor(parentMachine).start()
        reactor.childReactor(id: "counter")?.send(Event("INCREMENT"))
        reactor.childReactor(id: "counter")?.send(Event("INCREMENT"))

        await reactor.waitForSnapshot { $0.context.count == 2 }

        #expect(reactor.snapshot.context.count == 2)
    }
}
