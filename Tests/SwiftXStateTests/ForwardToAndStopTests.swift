import Foundation
import Testing
@testable import SwiftXState

private struct RelayContext: Sendable, Equatable {
    var gotPong: Bool
    var childId: String
}

@Suite("forwardTo and stop")
struct ForwardToAndStopTests {
    @Test("forwardTo delivers the triggering event to a child")
    func forwardsTriggeringEvent() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "active",
            context: RelayContext(gotPong: false, childId: "listener"),
            states: [
                "active": StateNodeConfig(
                    on: [
                        "PING": .single(TransitionConfig(actions: [forwardTo("listener")])),
                        "PONG": .single(TransitionConfig(
                            actions: [assign { ctx, _ in ctx.gotPong = true }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "listener",
                            src: fromCallback { scope in
                                scope.receive { event in
                                    if event.type == "PING" {
                                        scope.sendToParent(Event("PONG"))
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
        actor.send(Event("PING"))
        await actor.waitForSnapshot { $0.context.gotPong }

        #expect(actor.snapshot.context.gotPong)
    }

    @Test("forwardTo resolves child id from context")
    func forwardsWithExpression() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "active",
            context: RelayContext(gotPong: false, childId: "listener"),
            states: [
                "active": StateNodeConfig(
                    on: [
                        "PING": .single(TransitionConfig(actions: [
                            forwardTo { args in args.context.childId },
                        ])),
                        "PONG": .single(TransitionConfig(
                            actions: [assign { ctx, _ in ctx.gotPong = true }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "listener",
                            src: fromCallback { scope in
                                scope.receive { event in
                                    if event.type == "PING" {
                                        scope.sendToParent(Event("PONG"))
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
        actor.send(Event("PING"))
        await actor.waitForSnapshot { $0.context.gotPong }

        #expect(actor.snapshot.context.gotPong)
    }

    @Test("forwardTo records xstate.forwardTo in transition actions")
    func recordsActionType() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(actions: [forwardTo("child")])),
                ]),
            ]
        ))

        let (initial, _) = SwiftXState.initialTransition(machine)
        let (_, actions) = SwiftXState.transition(machine, snapshot: initial, event: Event("GO"))

        #expect(actions.contains { $0.type == "xstate.forwardTo" })
    }

    @Test("stop action stops an invoked child")
    func stopAction() async {
        let started = TestSignal()

        let parentMachine = createMachine(MachineConfig(
            initial: "withChild",
            context: EmptyContext(),
            states: [
                "withChild": StateNodeConfig(
                    on: [
                        "STOP": .single(TransitionConfig(actions: [stop("worker")])),
                    ],
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
            ]
        ))

        let actor = createActor(parentMachine).start()
        let didStart = await started.wait()
        await actor.waitForSnapshot { $0.children["worker"]?.status == .active }
        #expect(didStart)
        #expect(actor.snapshot.children["worker"]?.status == .active)

        actor.send(Event("STOP"))
        await actor.waitForSnapshot { $0.children["worker"] == nil }

        #expect(actor.snapshot.children["worker"] == nil)
        #expect(actor.snapshot.matches("withChild"))
    }

    @Test("stopChild expression resolves child id")
    func stopWithExpression() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "withChild",
            context: RelayContext(gotPong: false, childId: "worker"),
            states: [
                "withChild": StateNodeConfig(
                    on: [
                        "STOP": .single(TransitionConfig(actions: [
                            stopChild { args in args.context.childId },
                        ])),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: fromTask { _ in
                                try await Task.sleep(for: .seconds(10))
                                return "late"
                            }
                        ),
                    ]
                ),
            ]
        ))

        let actor = createActor(parentMachine).start()
        await actor.waitForSnapshot { $0.children["worker"]?.status == .active }
        #expect(actor.snapshot.children["worker"]?.status == .active)

        actor.send(Event("STOP"))
        await actor.waitForSnapshot { $0.children["worker"] == nil }

        #expect(actor.snapshot.children["worker"] == nil)
    }
}
