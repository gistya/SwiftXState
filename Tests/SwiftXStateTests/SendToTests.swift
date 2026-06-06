import Testing
@testable import SwiftXState

private struct SendToContext: Sendable, Equatable {
    var count: Int
    var childId: String
    var message: String
}

@Suite("sendTo action")
struct SendToTests {
    @Test("sendTo resolves child id from context")
    func expressionChildId() async {
        let childMachine = createMachine(MachineConfig(
            initial: "idle",
            context: SendToContext(count: 0, childId: "", message: ""),
            states: [
                "idle": StateNodeConfig(on: [
                    "PING": .single(TransitionConfig(
                        actions: [.sendParent(Event("PONG"))]
                    )),
                ]),
            ]
        ))

        let parentMachine = createMachine(MachineConfig(
            initial: "active",
            context: SendToContext(count: 0, childId: "worker", message: ""),
            states: [
                "active": StateNodeConfig(
                    on: [
                        "GO": .single(TransitionConfig(actions: [
                            sendTo({ args in args.context.childId }, Event("PING")),
                        ])),
                        "PONG": .single(TransitionConfig(
                            actions: [assign { ctx, _ in ctx.count += 1 }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: .machine(MachineActorLogicBox(childMachine) { _ in
                                SendToContext(count: 0, childId: "", message: "")
                            })
                        ),
                    ]
                ),
            ]
        ))

        let actor = createActor(parentMachine).start()
        actor.send(Event("GO"))
        await actor.waitForSnapshot { $0.context.count == 1 }

        #expect(actor.snapshot.context.count == 1)
    }

    @Test("sendTo resolves event type from context")
    func dynamicEventPayload() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "active",
            context: SendToContext(count: 0, childId: "listener", message: "HELLO"),
            states: [
                "active": StateNodeConfig(
                    on: [
                        "GO": .single(TransitionConfig(actions: [
                            sendTo("listener") { args in Event(args.context.message) },
                        ])),
                        "RECEIVED": .single(TransitionConfig(
                            actions: [assign { ctx, _ in ctx.count += 1 }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "listener",
                            src: fromCallback { scope in
                                scope.receive { event in
                                    if event.type == "HELLO" {
                                        scope.sendToParent(Event("RECEIVED"))
                                    }
                                }
                                return nil
                            }
                        ),
                    ]
                ),
            ]
        ))

        let actor = createActor(parentMachine).start()
        actor.send(Event("GO"))
        await actor.waitForSnapshot { $0.context.count == 1 }

        #expect(actor.snapshot.context.count == 1)
    }

    @Test("delayed sendTo delivers after delay")
    func delayedSendTo() async {
        let parentMachine = setup(
            delays: [
                "short": { _ in 20 },
            ]
        ).createMachine(MachineConfig(
            initial: "active",
            context: SendToContext(count: 0, childId: "worker", message: ""),
            states: [
                "active": StateNodeConfig(
                    on: [
                        "ARM": .single(TransitionConfig(actions: [
                            sendTo("worker", Event("TICK"), delay: "short"),
                        ])),
                        "TICK": .single(TransitionConfig(
                            actions: [assign { ctx, _ in ctx.count += 1 }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: fromCallback { scope in
                                scope.receive { event in
                                    if event.type == "TICK" {
                                        scope.sendToParent(event)
                                    }
                                }
                                return nil
                            }
                        ),
                    ]
                ),
            ]
        ))

        let actor = createActor(parentMachine).start()
        actor.send(Event("ARM"))
        await actor.waitForSnapshot { $0.context.count == 1 }

        #expect(actor.snapshot.context.count == 1)
    }

    @Test("cancel prevents a delayed sendTo from firing")
    func cancelDelayedSendTo() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "active",
            context: SendToContext(count: 0, childId: "worker", message: ""),
            states: [
                "active": StateNodeConfig(
                    on: [
                        "ARM": .single(TransitionConfig(actions: [
                            sendTo("worker", Event("TICK"), delay: 100, id: "tick-send"),
                        ])),
                        "CANCEL": .single(TransitionConfig(actions: [cancel("tick-send")])),
                        "TICK": .single(TransitionConfig(
                            actions: [assign { ctx, _ in ctx.count += 1 }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: fromCallback { scope in
                                scope.receive { event in
                                    if event.type == "TICK" {
                                        scope.sendToParent(event)
                                    }
                                }
                                return nil
                            }
                        ),
                    ]
                ),
            ]
        ))

        let actor = createActor(parentMachine).start()
        actor.send(Event("ARM"))
        actor.send(Event("CANCEL"))
        try? await Task.sleep(for: .milliseconds(150))

        #expect(actor.snapshot.context.count == 0)
    }

    @Test("sendTo records xstate.sendTo in transition actions")
    func recordsActionType() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(actions: [sendTo("child", Event("PING"))])),
                ]),
            ]
        ))

        let (initial, _) = SwiftXState.initialTransition(machine)
        let (_, actions) = SwiftXState.transition(machine, snapshot: initial, event: Event("GO"))

        #expect(actions.contains { $0.type == "xstate.sendTo" })
    }

    @Test("enqueueActions sendTo delivers to child")
    func enqueueSendTo() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "active",
            context: SendToContext(count: 0, childId: "worker", message: ""),
            states: [
                "active": StateNodeConfig(
                    on: [
                        "GO": .single(TransitionConfig(actions: [
                            enqueueActions { builder in
                                builder.sendTo("worker", Event("TICK"))
                            },
                        ])),
                        "TICK": .single(TransitionConfig(
                            actions: [assign { ctx, _ in ctx.count += 1 }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: fromCallback { scope in
                                scope.receive { event in
                                    if event.type == "TICK" {
                                        scope.sendToParent(event)
                                    }
                                }
                                return nil
                            }
                        ),
                    ]
                ),
            ]
        ))

        let actor = createActor(parentMachine).start()
        actor.send(Event("GO"))
        await actor.waitForSnapshot { $0.context.count == 1 }

        #expect(actor.snapshot.context.count == 1)
    }
}