import Testing
@testable import SwiftXState

private struct ParentContext: Sendable, Equatable {
    var count: Int
    var userName: String?
}

private struct ChildContext: Sendable, Equatable {
    var userId: String
    var userName: String?
}

@Suite("Invoke and spawn")
struct InvokeTests {
    @Test("invoked child machine completes with onDone")
    func invokedMachineOnDone() async {
        let childMachine = createMachine(MachineConfig(
            initial: "success",
            context: ChildContext(userId: "42", userName: "David"),
            states: [
                "success": StateNodeConfig(
                    type: .final,
                    output: { args in
                        SendableValue(args.context.userName ?? "")
                    }
                ),
            ]
        ))

        let parentMachine = createMachine(MachineConfig(
            id: "fetcher",
            initial: "idle",
            context: ParentContext(count: 0, userName: nil),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .to("waiting"),
                ]),
                "waiting": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "fetchUser",
                            src: .machine(MachineActorLogicBox(childMachine) { input in
                                ChildContext(
                                    userId: input?.get(String.self) ?? "",
                                    userName: "David"
                                )
                            }),
                            input: { _ in SendableValue("42") },
                            onDone: .single(TransitionConfig(
                                target: "received",
                                actions: [assign { ctx, args in
                                    if let event = args.event as? DoneActorEvent {
                                        ctx.userName = event.output?.get(String.self)
                                    }
                                }]
                            ))
                        ),
                    ]
                ),
                "received": StateNodeConfig(type: .final),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        await actor.send(Event("GO"))

        await actor.waitForSnapshot { $0.matches("received") }

        #expect(await actor.snapshot.matches("received"))
        #expect(await actor.snapshot.context.userName == "David")
        #expect(await actor.snapshot.status == .done)
    }

    @Test("named actor via setup invokes child machine")
    func namedActorInvoke() async {
        let childMachine = createMachine(MachineConfig(
            initial: "done",
            context: EmptyContext(),
            states: [
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let parentMachine = setup(
            actors: [
                "child": ActorLogicEntry(machine: MachineActorLogicBox(childMachine) { _ in
                    EmptyContext()
                }),
            ]
        ).createMachine(MachineConfig(
            initial: "running",
            context: EmptyContext(),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "childActor",
                            src: .named("child"),
                            onDone: .to("finished")
                        ),
                    ]
                ),
                "finished": StateNodeConfig(type: .final),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        await actor.waitForSnapshot { $0.matches("finished") }

        #expect(await actor.snapshot.matches("finished"))
        #expect(await actor.snapshot.status == .done)
    }

    @Test("fromTask invokes async work")
    func fromTaskInvoke() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "running",
            context: ParentContext(count: 0, userName: nil),
            states: [
                "running": StateNodeConfig(
                    on: [
                        "TICK": .single(TransitionConfig(
                            actions: [assign { ctx, _ in ctx.count += 1 }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: fromTask { scope in
                                try await Task.sleep(for: .milliseconds(10))
                                scope.sendToParent(Event("TICK"))
                                return "ok"
                            },
                            onDone: .single(TransitionConfig(
                                target: "done",
                                actions: [assign { ctx, args in
                                    if let event = args.event as? DoneActorEvent {
                                        ctx.userName = event.output?.get(String.self)
                                    }
                                }]
                            ))
                        ),
                    ]
                ),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        await actor.waitForSnapshot { $0.matches("done") }
        let snapshot = await actor.snapshot
        
        #expect(snapshot.context.count == 1)
        #expect(snapshot.matches("done"))
        #expect(snapshot.context.userName == "ok")
    }

    @Test("sendTo delivers events to invoked child")
    func sendToChild() async {
        let childMachine = createMachine(MachineConfig(
            initial: "idle",
            context: ParentContext(count: 0, userName: nil),
            states: [
                "idle": StateNodeConfig(on: [
                    "FORWARD": .single(TransitionConfig(
                        actions: [.sendToParent(Event("DEC"))]
                    )),
                ]),
            ]
        ))

        let parentMachine = setup(
            actors: [
                "child": ActorLogicEntry(machine: MachineActorLogicBox(childMachine) { _ in
                    ParentContext(count: 0, userName: nil)
                }),
            ]
        ).createMachine(MachineConfig(
            initial: "start",
            context: ParentContext(count: 0, userName: nil),
            states: [
                "start": StateNodeConfig(
                    on: [
                        "FORWARD_DEC": .single(TransitionConfig(
                            actions: [sendTo("someService", Event("FORWARD"))]
                        )),
                        "DEC": .single(TransitionConfig(
                            actions: [assign { ctx, _ in ctx.count -= 1 }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(id: "someService", src: .named("child")),
                    ]
                ),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        for _ in 0..<3 {
            await actor.send(Event("FORWARD_DEC"))
        }
        await actor.waitForSnapshot { $0.context.count == -3 }
        #expect(await actor.snapshot.context.count == -3)
    }

    @Test("stops invoked child when leaving state")
    func stopsOnExit() async {
        let started = TestSignal()

        let parentMachine = createMachine(MachineConfig(
            initial: "withChild",
            context: EmptyContext(),
            states: [
                "withChild": StateNodeConfig(
                    on: ["LEAVE": .to("alone")],
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: fromTask { _ in
                                started.fire()
                                try await Task.sleep(for: .seconds(10))
                                return "late"
                            }
                        ),
                    ]
                ),
                "alone": StateNodeConfig(),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        let didStart = await started.wait()
        await actor.waitForSnapshot { $0.children["worker"]?.status == .active }
        #expect(didStart)
        #expect(await actor.snapshot.children["worker"]?.status == .active)

        await actor.send(Event("LEAVE"))
        await actor.waitForSnapshot { $0.matches("alone") && $0.children["worker"] == nil }

        #expect(await actor.snapshot.children["worker"] == nil)
        #expect(await actor.snapshot.matches("alone"))
    }

    @Test("fromCallback receives events and forwards to parent")
    func fromCallbackInvoke() async {
        let received = TestSignal()

        let parentMachine = createMachine(MachineConfig(
            initial: "listening",
            context: EmptyContext(),
            states: [
                "listening": StateNodeConfig(
                    on: [
                        "PING": .single(TransitionConfig(
                            actions: [.inline { _ in received.fire() }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "listener",
                            src: fromCallback { scope in
                                scope.receive { event in
                                    if event.type == "PING" {
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

        let actor = await createActor(parentMachine).start()
        await actor.childActor(id: "listener")?.send(Event("PING"))

        #expect(await received.wait())
    }

    @Test("fromCallback sendBack delivers events to parent")
    func fromCallbackSendBack() async {
        let resized = TestSignal()
        let forwarded = TestSignal()

        let parentMachine = createMachine(MachineConfig(
            initial: "listening",
            context: EmptyContext(),
            states: [
                "listening": StateNodeConfig(
                    on: [
                        "RESIZE": .single(TransitionConfig(
                            actions: [.inline { _ in resized.fire() }]
                        )),
                        "FORWARD": .single(TransitionConfig(
                            actions: [.inline { _ in forwarded.fire() }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "listener",
                            src: fromCallback { scope in
                                scope.sendBack(Event("RESIZE"))
                                scope.receive { event in
                                    if event.type == "FORWARD" {
                                        scope.sendBack(event)
                                    }
                                }
                                return nil
                            }
                        ),
                    ]
                ),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        #expect(await resized.wait())

        await actor.childActor(id: "listener")?.send(Event("FORWARD"))
        #expect(await forwarded.wait())
    }

    @Test("onSnapshot syncs child machine snapshot to parent")
    func onSnapshotSync() async {
        let childMachine = createMachine(MachineConfig(
            initial: "idle",
            context: ParentContext(count: 0, userName: nil),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                ]),
            ]
        ))

        let parentMachine = createMachine(MachineConfig(
            initial: "running",
            context: ParentContext(count: 0, userName: nil),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "counter",
                            src: .machine(MachineActorLogicBox(childMachine) { _ in
                                ParentContext(count: 0, userName: nil)
                            }),
                            onSnapshot: .single(TransitionConfig(
                                actions: [assign { ctx, _ in ctx.count = 1 }]
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        await actor.childActor(id: "counter")?.send(Event("INC"))
        await actor.waitForSnapshot { $0.context.count == 1 }

        #expect(await actor.snapshot.context.count == 1)
    }

    @Test("actor system registry resolves children by systemId")
    func actorSystemRegistry() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "running",
            context: EmptyContext(),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: fromTask { _ in
                                try await Task.sleep(for: .milliseconds(10))
                                return "done"
                            },
                            systemId: "myWorker"
                        ),
                    ]
                ),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        await actor.waitForSnapshot { $0.children["worker"] != nil }

        let registered = actor.actorSystem.get(systemId: "myWorker")
        #expect(registered != nil)
        #expect(registered?.systemId == "myWorker")
    }

    @Test("fromTaskGroup runs concurrent work and completes")
    func fromTaskGroupInvoke() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "running",
            context: ParentContext(count: 0, userName: nil),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "batch",
                            src: fromTaskGroup { scope in
                                try await scope.runGroup([
                                    { @Sendable in
                                        try await Task.sleep(for: .milliseconds(10))
                                        return 1
                                    },
                                    { @Sendable in
                                        try await Task.sleep(for: .milliseconds(5))
                                        return 2
                                    },
                                ])
                            },
                            onDone: .single(TransitionConfig(
                                target: "done",
                                actions: [assign { ctx, args in
                                    if let event = args.event as? DoneActorEvent,
                                       let outputs = event.output?.get([Int].self) {
                                        ctx.count = outputs.reduce(0, +)
                                    }
                                }]
                            ))
                        ),
                    ]
                ),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        await actor.waitForSnapshot { $0.matches("done") }

        #expect(await actor.snapshot.matches("done"))
        #expect(await actor.snapshot.context.count == 3)
    }

    @Test("spawnChild action starts a child from entry")
    func spawnChildAction() async {
        let done = TestSignal()

        let parentMachine = createMachine(MachineConfig(
            initial: "idle",
            context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(
                    on: [
                        createDoneActorEventType("spawned"): .single(TransitionConfig(
                            actions: [.inline { _ in done.fire() }]
                        )),
                    ],
                    entry: [
                        .spawn(SpawnRef(
                            src: fromTask { _ in
                                try await Task.sleep(for: .milliseconds(10))
                                return true
                            },
                            id: "spawned"
                        )),
                    ]
                ),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        let fired = await done.wait()

        #expect(fired)
        #expect(await actor.snapshot.children["spawned"] != nil)
    }
}
