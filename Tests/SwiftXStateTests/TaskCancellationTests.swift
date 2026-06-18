import Foundation
import Testing
@testable import SwiftXState

@Suite("Task cancellation and opaque restore policy")
struct TaskCancellationTests {
    @Test("fromTask onCancel runs when invoked child is stopped")
    func taskOnCancelOnStop() async {
        let cancelled = TestSignal()

        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(on: ["START": .to("working")]),
                "working": StateNodeConfig(
                    on: ["STOP": .to("idle")],
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: fromTask(onCancel: { _ in
                                cancelled.fire()
                            }) { _ in
                                try await Task.sleep(for: .seconds(2))
                                return 42
                            }
                        ),
                    ]
                ),
            ]
        ))

        let reactor = createReactor(machine).start()
        reactor.send(Event("START"))
        reactor.send(Event("STOP"))

        #expect(await cancelled.wait())
    }

    @Test("TaskReactorScope checkCancellation stops in-flight work")
    func scopeCheckCancellation() async {
        let cancelled = TestSignal()

        let machine = createMachine(MachineConfig(
            initial: "working",
            context: EmptyContext(),
            states: [
                "working": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: fromTask(onCancel: { _ in
                                cancelled.fire()
                            }) { scope in
                                for _ in 0 ..< 50 {
                                    try scope.checkCancellation()
                                    try await Task.sleep(for: .milliseconds(20))
                                }
                                return true
                            }
                        ),
                    ]
                ),
            ]
        ))

        let reactor = createReactor(machine).start()
        reactor.stop()

        #expect(await cancelled.wait())
    }

    @Test("fromTaskGroup onCancel runs when task group child is stopped")
    func taskGroupOnCancelOnStop() async {
        let cancelled = TestSignal()

        let machine = createMachine(MachineConfig(
            initial: "working",
            context: EmptyContext(),
            states: [
                "working": StateNodeConfig(
                    on: ["STOP": .to("idle")],
                    invoke: [
                        InvokeConfig(
                            id: "group",
                            src: fromTaskGroup(onCancel: { _ in
                                cancelled.fire()
                            }) { _ in
                                try await Task.sleep(for: .seconds(2))
                                return [1, 2, 3]
                            }
                        ),
                    ]
                ),
                "idle": StateNodeConfig(),
            ]
        ))

        let reactor = createReactor(machine).start()
        reactor.send(Event("STOP"))

        #expect(await cancelled.wait())
    }

    @Test("opaqueRestorePolicy skipIfActive avoids re-spawn on hydrate")
    func skipIfActiveOnRestore() throws {
        struct ParentContext: Sendable, Equatable, Codable {
            var label: String
        }

        let parentMachine = createMachine(MachineConfig(
            id: "parent",
            initial: "working",
            context: ParentContext(label: "main"),
            states: [
                "working": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "task",
                            src: fromTask { _ in
                                try await Task.sleep(for: .seconds(5))
                                return 1
                            },
                            opaqueRestorePolicy: .skipIfActive
                        ),
                    ]
                ),
            ]
        ))

        let reactor = createReactor(parentMachine).start()
        let persisted = try reactor.getPersistedSnapshot()
        #expect(persisted.children["task"] != nil)

        let restored = createReactor(parentMachine).start(from: persisted)
        #expect(restored.childReactor(id: "task") == nil)
        #expect(restored.snapshot.children["task"]?.status == .active)
    }
}
