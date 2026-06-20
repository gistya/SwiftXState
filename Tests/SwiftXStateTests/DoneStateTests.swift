import Testing
@testable import SwiftXState

private struct WorkflowContext: Sendable, Equatable {
    var result: String?
}

@Suite("xstate.done.state")
struct DoneStateTests {
    @Test("nested final raises done.state and parent onDone transitions")
    func nestedFinalOnDone() async {
        let machine = createMachine(MachineConfig(
            id: "workflow",
            initial: "running",
            context: WorkflowContext(result: nil),
            states: [
                "running": StateNodeConfig(
                    initial: "step1",
                    states: [
                        "step1": StateNodeConfig(on: [
                            "NEXT": .to("step2"),
                        ]),
                        "step2": StateNodeConfig(
                            initial: "work",
                            states: [
                                "work": StateNodeConfig(on: [
                                    "DONE": .to("success"),
                                ]),
                                "success": StateNodeConfig(
                                    type: .final,
                                    output: { _ in SendableValue("ok") }
                                ),
                            ],
                            onDone: .single(TransitionConfig(
                                target: "finished",
                                actions: [assign { ctx, args in
                                    if let event = args.event as? DoneStateEvent {
                                        ctx.result = event.output?.get(String.self)
                                    }
                                }]
                            ))
                        ),
                        "finished": StateNodeConfig(type: .atomic),
                    ]
                ),
            ]
        ))

        let actor = await createActor(machine).start()
        await actor.send(Event("NEXT"))
        await actor.send(Event("DONE"))

        #expect(await actor.snapshot.status == .active)
        #expect(await actor.snapshot.matches("running.finished"))
        #expect(await actor.snapshot.context.result == "ok")
    }

    @Test("parallel regions complete before parallel onDone fires")
    func parallelOnDone() async {
        let machine = createMachine(MachineConfig(
            id: "parallel-workflow",
            initial: "work",
            context: EmptyContext(),
            states: [
                "work": StateNodeConfig(
                    type: .parallel,
                    states: [
                        "foo": StateNodeConfig(
                            initial: "idle",
                            states: [
                                "idle": StateNodeConfig(on: ["FOO_DONE": .to("success")]),
                                "success": StateNodeConfig(type: .final),
                            ]
                        ),
                        "bar": StateNodeConfig(
                            initial: "idle",
                            states: [
                                "idle": StateNodeConfig(on: ["BAR_DONE": .to("success")]),
                                "success": StateNodeConfig(type: .final),
                            ]
                        ),
                    ],
                    onDone: .to("completed")
                ),
                "completed": StateNodeConfig(type: .final),
            ]
        ))

        let actor = await createActor(machine).start()
        await actor.send(Event("FOO_DONE"))
        #expect(await actor.snapshot.matches("work"))
        #expect(await actor.snapshot.status == .active)

        await actor.send(Event("BAR_DONE"))
        #expect(await actor.snapshot.matches("completed"))
        #expect(await actor.snapshot.status == .done)
    }

    @Test("top-level final completes machine with output")
    func topLevelFinalOutput() async {
        let machine = createMachine(MachineConfig(
            initial: "go",
            context: EmptyContext(),
            states: [
                "go": StateNodeConfig(on: ["FINISH": .to("done")]),
                "done": StateNodeConfig(
                    type: .final,
                    output: { _ in SendableValue(42) }
                ),
            ]
        ))

        let actor = await createActor(machine).start()
        await actor.send(Event("FINISH"))

        #expect(await actor.snapshot.status == .done)
        #expect(await actor.snapshot.output?.get(Int.self) == 42)
    }

    @Test("machine output resolver receives done.state event")
    func rootOutputFromDoneStateEvent() async {
        let machine = createMachine(MachineConfig(
            id: "root-output",
            initial: "go",
            context: EmptyContext(),
            states: [
                "go": StateNodeConfig(on: ["FINISH": .to("done")]),
                "done": StateNodeConfig(type: .final),
            ],
            output: { args in
                guard let event = args.event as? DoneStateEvent else { return nil }
                return SendableValue(event.stateId)
            }
        ))

        let actor = await createActor(machine).start()
        await actor.send(Event("FINISH"))

        #expect(await actor.snapshot.status == .done)
        #expect(await actor.snapshot.output?.get(String.self) == "root-output.done")
    }
}
