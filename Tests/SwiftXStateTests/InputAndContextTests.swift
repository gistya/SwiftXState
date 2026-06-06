import Testing
@testable import SwiftXState

private struct LabeledCounterContext: Sendable, Equatable {
    var count: Int
    var label: String
}

private struct CounterInput: Sendable, Equatable {
    var startCount: Int
    var label: String
}

private struct InputParentContext: Sendable, Equatable {
    var childLabel: String?
}

private struct InputChildContext: Sendable, Equatable {
    var userId: String
    var label: String
}

@Suite("Actor input and context initializer")
struct InputAndContextTests {
    private func counterMachine(
        contextFromInput: @escaping @Sendable (SendableValue?) -> LabeledCounterContext
    ) -> StateMachine<LabeledCounterContext> {
        createMachine(MachineConfig(
            id: "counter",
            initial: "idle",
            contextFromInput: contextFromInput,
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                ]),
            ]
        ))
    }

    @Test("createActor input builds context via contextFromInput")
    func actorInputBuildsContext() {
        let machine = counterMachine { input in
            LabeledCounterContext(
                count: input?.get(CounterInput.self)?.startCount ?? 0,
                label: input?.get(CounterInput.self)?.label ?? ""
            )
        }

        let actor = createActor(
            machine,
            input: CounterInput(startCount: 5, label: "main")
        ).start()

        #expect(actor.snapshot.context.count == 5)
        #expect(actor.snapshot.context.label == "main")
    }

    @Test("start(input:) overrides ActorOptions input")
    func startInputOverridesOptions() {
        let machine = counterMachine { input in
            LabeledCounterContext(
                count: input?.get(Int.self) ?? 0,
                label: "from-input"
            )
        }

        let actor = createActor(
            machine,
            options: ActorOptions(input: SendableValue(1))
        ).start(input: SendableValue(9))

        #expect(actor.snapshot.context.count == 9)
    }

    @Test("static context still works without input")
    func staticContextBackwardCompat() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: LabeledCounterContext(count: 3, label: "static"),
            states: ["idle": StateNodeConfig()]
        ))

        let actor = createActor(machine).start()

        #expect(actor.snapshot.context.count == 3)
        #expect(actor.snapshot.context.label == "static")
    }

    @Test("explicit start(context:) overrides contextFromInput")
    func explicitContextOverridesInput() {
        let machine = counterMachine { input in
            LabeledCounterContext(
                count: input?.get(Int.self) ?? 0,
                label: "from-input"
            )
        }

        let actor = createActor(machine, input: 10)
            .start(context: LabeledCounterContext(count: 99, label: "override"))

        #expect(actor.snapshot.context.count == 99)
        #expect(actor.snapshot.context.label == "override")
    }

    @Test("invoked child uses machine contextFromInput")
    func invokedChildUsesMachineContextFromInput() async {
        let childMachine = createMachine(MachineConfig(
            initial: "done",
            contextFromInput: { input in
                InputChildContext(
                    userId: input?.get(String.self) ?? "",
                    label: input?.get(String.self).map { "user-\($0)" } ?? ""
                )
            },
            states: [
                "done": StateNodeConfig(
                    type: .final,
                    output: { args in SendableValue(args.context.label) }
                ),
            ]
        ))

        let parentMachine = createMachine(MachineConfig(
            initial: "waiting",
            context: InputParentContext(childLabel: nil),
            states: [
                "waiting": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "child",
                            src: .machine(MachineActorLogicBox(childMachine)),
                            input: { _ in SendableValue("42") },
                            onDone: .single(TransitionConfig(
                                target: "received",
                                actions: [assign { ctx, args in
                                    if let event = args.event as? DoneActorEvent {
                                        ctx.childLabel = event.output?.get(String.self)
                                    }
                                }]
                            ))
                        ),
                    ]
                ),
                "received": StateNodeConfig(type: .final),
            ]
        ))

        let actor = createActor(parentMachine).start()
        await actor.waitForSnapshot { $0.matches("received") }

        #expect(actor.snapshot.matches("received"))
        #expect(actor.snapshot.context.childLabel == "user-42")
    }

    @Test("fromMachine uses machine contextFromInput")
    func fromMachineUsesContextFromInput() async {
        let childMachine = createMachine(MachineConfig(
            initial: "done",
            contextFromInput: { input in
                InputChildContext(
                    userId: input?.get(String.self) ?? "",
                    label: "from-machine"
                )
            },
            states: ["done": StateNodeConfig(type: .final)]
        ))

        let parentMachine = setup(actors: [
            "childActor": ActorLogicEntry(machine: MachineActorLogicBox(childMachine)),
        ]).createMachine(MachineConfig(
            initial: "waiting",
            context: InputParentContext(childLabel: nil),
            states: [
                "waiting": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "child",
                            src: .named("childActor"),
                            input: { _ in SendableValue("7") }
                        ),
                    ]
                ),
            ]
        ))

        let actor = createActor(parentMachine).start()
        await actor.waitForSnapshot { $0.children["child"]?.status == .done }

        #expect(actor.snapshot.matches("waiting"))
        #expect(actor.snapshot.children["child"]?.status == .done)
    }
}