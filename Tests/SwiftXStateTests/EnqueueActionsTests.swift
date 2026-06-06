import Testing
@testable import SwiftXState

private struct QueueContext: Sendable, Equatable, Codable {
    var armed: Bool
    var fired: Bool
}

@Suite("enqueueActions")
struct EnqueueActionsTests {
    @Test("enqueueActions runs guarded action batches")
    func guardedEnqueue() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: QueueContext(armed: true, fired: false),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(
                        target: "done",
                        actions: [
                            enqueueActions { enqueue in
                                if enqueue.check(.inline { $0.context.armed }) {
                                    enqueue.enqueue(assign { ctx, _ in ctx.fired = true })
                                }
                            },
                        ]
                    )),
                ]),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let (initial, _) = SwiftXState.initialTransition(machine)
        let (next, actions) = SwiftXState.transition(machine, snapshot: initial, event: Event("GO"))

        #expect(next.matches("done"))
        #expect(next.context.fired)
        #expect(actions.contains { $0.type == "xstate.enqueueActions" })
        #expect(actions.contains { $0.type == "xstate.assign" })
    }

    @Test("enqueueActions skips actions when guard fails")
    func guardedEnqueueSkips() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: QueueContext(armed: false, fired: false),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(
                        target: "done",
                        actions: [
                            enqueueActions { enqueue in
                                if enqueue.check(.inline { $0.context.armed }) {
                                    enqueue.enqueue(assign { ctx, _ in ctx.fired = true })
                                }
                            },
                        ]
                    )),
                ]),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let (initial, _) = SwiftXState.initialTransition(machine)
        let (next, _) = SwiftXState.transition(machine, snapshot: initial, event: Event("GO"))

        #expect(next.matches("done"))
        #expect(!next.context.fired)
    }
}