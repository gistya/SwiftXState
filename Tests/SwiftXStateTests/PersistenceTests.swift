import Foundation
import Testing
@testable import SwiftXState

private struct PersistCounterContext: Sendable, Equatable, Codable {
    var count: Int
}

@Suite("Reactor persistence")
struct PersistenceTests {
    private var counterMachine: StateMachine<PersistCounterContext> {
        createMachine(MachineConfig(
            id: "counter",
            initial: "idle",
            context: PersistCounterContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                    "DONE": .to("finished"),
                ]),
                "finished": StateNodeConfig(type: .final),
            ]
        ))
    }

    @Test("getPersistedSnapshot round-trips through restoreSnapshot")
    func roundTrip() throws {
        let machine = counterMachine
        let reactor = createReactor(machine).start(context: PersistCounterContext(count: 0))
        reactor.send(Event("INC"))
        reactor.send(Event("INC"))

        let persisted = try reactor.getPersistedSnapshot()
        let restored = try restoreSnapshot(machine: machine, persisted: persisted)

        #expect(restored.value == reactor.snapshot.value)
        #expect(restored.context.count == 2)
        #expect(restored.matches("idle"))
        #expect(restored.tags == reactor.snapshot.tags)
    }

    @Test("reactor starts from persisted snapshot and continues transitioning")
    func startFromPersisted() throws {
        let machine = counterMachine
        let original = createReactor(machine).start(context: PersistCounterContext(count: 0))
        original.send(Event("INC"))
        let persisted = try original.getPersistedSnapshot()

        let restoredReactor = createReactor(machine).start(from: persisted)

        #expect(restoredReactor.snapshot.context.count == 1)
        #expect(restoredReactor.snapshot.matches("idle"))

        restoredReactor.send(Event("INC"))
        restoredReactor.send(Event("DONE"))

        #expect(restoredReactor.snapshot.matches("finished"))
        #expect(restoredReactor.snapshot.context.count == 2)
        #expect(restoredReactor.snapshot.status == .done)
    }

    @Test("createReactor with snapshot hydrates in one step")
    func createReactorWithSnapshot() throws {
        let machine = counterMachine
        let original = createReactor(machine).start(context: PersistCounterContext(count: 0))
        original.send(Event("INC"))
        original.send(Event("INC"))
        let persisted = try original.getPersistedSnapshot()

        let restoredReactor = createReactor(machine, snapshot: persisted)

        #expect(restoredReactor.snapshot.context.count == 2)
        #expect(restoredReactor.snapshot.matches("idle"))
        #expect(restoredReactor.snapshot.status == .active)

        restoredReactor.send(Event("DONE"))
        #expect(restoredReactor.snapshot.matches("finished"))
        #expect(restoredReactor.snapshot.status == .done)
    }

    @Test("createReactor with snapshot accepts context override")
    func createReactorWithSnapshotContextOverride() throws {
        let machine = counterMachine
        let original = createReactor(machine).start(context: PersistCounterContext(count: 0))
        original.send(Event("INC"))
        let persisted = try original.getPersistedSnapshot()

        let restoredReactor = createReactor(
            machine,
            snapshot: persisted,
            context: PersistCounterContext(count: 99)
        )

        #expect(restoredReactor.snapshot.context.count == 99)
        #expect(restoredReactor.snapshot.matches("idle"))
    }

    @Test("persisted JSON survives encode and decode")
    func jsonRoundTrip() throws {
        let reactor = createReactor(counterMachine).start(context: PersistCounterContext(count: 3))
        reactor.send(Event("INC"))

        let persisted = try reactor.getPersistedSnapshot()
        let data = try persisted.encodeJSON()
        let decoded = try PersistedSnapshot.decodeJSON(data)

        let restored = try restoreSnapshot(machine: counterMachine, persisted: decoded)
        #expect(restored.context.count == 4)
    }

    @Test("persisted snapshot includes invoked child machine state")
    func childMachinePersistence() throws {
        struct WorkerContext: Sendable, Equatable, Codable {
            var count: Int
        }

        struct ParentContext: Sendable, Equatable, Codable {
            var label: String
        }

        let childMachine = createMachine(MachineConfig(
            id: "worker",
            initial: "idle",
            context: WorkerContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                ]),
            ]
        ))

        let parentMachine = createMachine(MachineConfig(
            id: "parent",
            initial: "idle",
            context: ParentContext(label: "main"),
            states: [
                "idle": StateNodeConfig(on: ["GO": .to("working")]),
                "working": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: .machine(MachineReactorLogicBox(childMachine))
                        ),
                    ]
                ),
            ]
        ))

        let reactor = createReactor(parentMachine).start()
        reactor.send(Event("GO"))
        reactor.childReactor(id: "worker")?.send(Event("INC"))
        reactor.childReactor(id: "worker")?.send(Event("INC"))

        let persisted = try reactor.getPersistedSnapshot()
        #expect(persisted.children["worker"] != nil)
        if case let .machine(childPersisted) = persisted.children["worker"] {
            let childContext = try JSONDecoder().decode(
                WorkerContext.self,
                from: childPersisted.context
            )
            #expect(childContext.count == 2)
        } else {
            Issue.record("Expected machine child snapshot")
        }

        let restored = createReactor(parentMachine).start(from: persisted)
        guard let child = restored.childReactor(id: "worker") as? MachineChildRef<WorkerContext> else {
            Issue.record("Expected restored machine child")
            return
        }

        #expect(child.reactor.snapshot.context.count == 2)
        #expect(restored.snapshot.matches("working"))
    }

    @Test("backward compatible persisted JSON without children field")
    func legacyPersistedJSON() throws {
        let reactor = createReactor(counterMachine).start(context: PersistCounterContext(count: 1))
        let persisted = try reactor.getPersistedSnapshot()
        let data = try persisted.encodeJSON()

        var object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        object?.removeValue(forKey: "children")
        let legacyData = try JSONSerialization.data(withJSONObject: object!)

        let decoded = try PersistedSnapshot.decodeJSON(legacyData)
        let restored = try restoreSnapshot(machine: counterMachine, persisted: decoded)
        #expect(restored.context.count == 1)
        #expect(decoded.children.isEmpty)
    }

    @Test("persisted snapshot includes nested grandchild machine state")
    func nestedGrandchildPersistence() throws {
        struct LeafContext: Sendable, Equatable, Codable {
            var count: Int
        }

        struct MidContext: Sendable, Equatable, Codable {
            var label: String
        }

        struct RootContext: Sendable, Equatable, Codable {
            var label: String
        }

        let leafMachine = createMachine(MachineConfig(
            id: "leaf",
            initial: "idle",
            context: LeafContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                ]),
            ]
        ))

        let midMachine = createMachine(MachineConfig(
            id: "mid",
            initial: "idle",
            context: MidContext(label: "mid"),
            states: [
                "idle": StateNodeConfig(on: ["GO": .to("working")]),
                "working": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "leaf",
                            src: .machine(MachineReactorLogicBox(leafMachine))
                        ),
                    ]
                ),
            ]
        ))

        let rootMachine = createMachine(MachineConfig(
            id: "root",
            initial: "idle",
            context: RootContext(label: "root"),
            states: [
                "idle": StateNodeConfig(on: ["GO": .to("working")]),
                "working": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "mid",
                            src: .machine(MachineReactorLogicBox(midMachine))
                        ),
                    ]
                ),
            ]
        ))

        let reactor = createReactor(rootMachine).start()
        reactor.send(Event("GO"))
        guard let midChild = reactor.childReactor(id: "mid") as? MachineChildRef<MidContext> else {
            Issue.record("Expected mid child reactor")
            return
        }
        midChild.send(Event("GO"))
        midChild.reactor.childReactor(id: "leaf")?.send(Event("INC"))
        midChild.reactor.childReactor(id: "leaf")?.send(Event("INC"))
        midChild.reactor.childReactor(id: "leaf")?.send(Event("INC"))

        let persisted = try reactor.getPersistedSnapshot()
        if case let .machine(midPersisted) = persisted.children["mid"],
           case let .machine(leafPersisted) = midPersisted.children["leaf"] {
            let leafContext = try JSONDecoder().decode(
                LeafContext.self,
                from: leafPersisted.context
            )
            #expect(leafContext.count == 3)
        } else {
            Issue.record("Expected nested machine child snapshots")
        }

        let restored = createReactor(rootMachine).start(from: persisted)
        guard let mid = restored.childReactor(id: "mid") as? MachineChildRef<MidContext>,
              let leaf = mid.reactor.childReactor(id: "leaf") as? MachineChildRef<LeafContext> else {
            Issue.record("Expected restored nested machine children")
            return
        }

        #expect(mid.reactor.snapshot.matches("working"))
        #expect(leaf.reactor.snapshot.context.count == 3)
    }

    @Test("persisted snapshot restores multiple parallel invoked children")
    func parallelInvokePersistence() throws {
        struct WorkerContext: Sendable, Equatable, Codable {
            var count: Int
        }

        struct ParentContext: Sendable, Equatable, Codable {
            var label: String
        }

        let workerAMachine = createMachine(MachineConfig(
            id: "workerA",
            initial: "idle",
            context: WorkerContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                ]),
            ]
        ))

        let workerBMachine = createMachine(MachineConfig(
            id: "workerB",
            initial: "idle",
            context: WorkerContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 2 }]
                    )),
                ]),
            ]
        ))

        let parentMachine = createMachine(MachineConfig(
            id: "parent",
            initial: "active",
            context: ParentContext(label: "main"),
            states: [
                "regionA": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "workerA",
                            src: .machine(MachineReactorLogicBox(workerAMachine))
                        ),
                    ]
                ),
                "regionB": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "workerB",
                            src: .machine(MachineReactorLogicBox(workerBMachine))
                        ),
                    ]
                ),
            ],
            type: .parallel
        ))

        let reactor = createReactor(parentMachine).start()
        reactor.childReactor(id: "workerA")?.send(Event("INC"))
        reactor.childReactor(id: "workerB")?.send(Event("INC"))
        reactor.childReactor(id: "workerB")?.send(Event("INC"))

        let persisted = try reactor.getPersistedSnapshot()
        let restored = createReactor(parentMachine).start(from: persisted)

        guard let workerA = restored.childReactor(id: "workerA") as? MachineChildRef<WorkerContext>,
              let workerB = restored.childReactor(id: "workerB") as? MachineChildRef<WorkerContext> else {
            Issue.record("Expected restored parallel machine children")
            return
        }

        #expect(workerA.reactor.snapshot.context.count == 1)
        #expect(workerB.reactor.snapshot.context.count == 4)
    }

    @Test("spawned machine child state survives persist and restore")
    func spawnedMachineChildPersistence() throws {
        struct ChildContext: Sendable, Equatable, Codable {
            var count: Int
        }

        struct ParentContext: Sendable, Equatable, Codable {
            var label: String
        }

        let childMachine = createMachine(MachineConfig(
            id: "spawnedWorker",
            initial: "idle",
            context: ChildContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                ]),
            ]
        ))

        let parentMachine = createMachine(MachineConfig(
            id: "parent",
            initial: "idle",
            context: ParentContext(label: "main"),
            states: [
                "idle": StateNodeConfig(
                    entry: [
                        .spawn(SpawnRef(
                            src: .machine(MachineReactorLogicBox(childMachine)),
                            id: "spawnedWorker"
                        )),
                    ]
                ),
            ]
        ))

        let reactor = createReactor(parentMachine).start()
        reactor.childReactor(id: "spawnedWorker")?.send(Event("INC"))
        reactor.childReactor(id: "spawnedWorker")?.send(Event("INC"))

        let persisted = try reactor.getPersistedSnapshot()
        let restored = createReactor(parentMachine).start(from: persisted)

        guard let child = restored.childReactor(id: "spawnedWorker") as? MachineChildRef<ChildContext> else {
            Issue.record("Expected restored spawned machine child")
            return
        }

        #expect(child.reactor.snapshot.context.count == 2)
    }

    @Test("restoring done child does not re-emit DoneReactorEvent")
    func restoredDoneChildDoesNotReemit() throws {
        struct ChildContext: Sendable, Equatable, Codable {
            var value: String
        }

        struct ParentContext: Sendable, Equatable, Codable {
            var doneCount: Int
        }

        let childMachine = createMachine(MachineConfig(
            id: "worker",
            initial: "go",
            context: ChildContext(value: "ok"),
            states: [
                "go": StateNodeConfig(type: .final),
            ]
        ))

        let parentMachine = createMachine(MachineConfig(
            id: "parent",
            initial: "idle",
            context: ParentContext(doneCount: 0),
            states: [
                "idle": StateNodeConfig(on: ["GO": .to("working")]),
                "working": StateNodeConfig(
                    on: [
                        createDoneReactorEventType("worker"): .single(TransitionConfig(
                            actions: [assign { ctx, _ in ctx.doneCount += 1 }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: .machine(MachineReactorLogicBox(childMachine))
                        ),
                    ]
                ),
            ]
        ))

        let reactor = createReactor(parentMachine).start()
        reactor.send(Event("GO"))
        #expect(reactor.snapshot.context.doneCount == 1)

        let persisted = try reactor.getPersistedSnapshot()
        let restored = createReactor(parentMachine).start(from: persisted)

        #expect(restored.snapshot.context.doneCount == 1)
        #expect(restored.snapshot.matches("working"))
    }

    @Test("persisted snapshot records opaque task child status")
    func opaqueTaskChildPersistence() throws {
        struct ParentContext: Sendable, Equatable, Codable {
            var label: String
        }

        let parentMachine = createMachine(MachineConfig(
            id: "parent",
            initial: "idle",
            context: ParentContext(label: "main"),
            states: [
                "idle": StateNodeConfig(on: ["GO": .to("working")]),
                "working": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "task",
                            src: fromTask { _ in
                                try await Task.sleep(for: .milliseconds(200))
                                return 42
                            }
                        ),
                    ]
                ),
            ]
        ))

        let reactor = createReactor(parentMachine).start()
        reactor.send(Event("GO"))

        let activePersisted = try reactor.getPersistedSnapshot()
        if case let .opaque(opaque) = activePersisted.children["task"] {
            #expect(opaque.status == .active)
        } else {
            Issue.record("Expected opaque active task child snapshot")
        }
    }

    @Test("rejects machine mismatch on restore")
    func machineMismatch() throws {
        let otherMachine = createMachine(MachineConfig(
            id: "other",
            initial: "idle",
            context: PersistCounterContext(count: 0),
            states: ["idle": StateNodeConfig()]
        ))

        let reactor = createReactor(counterMachine).start()
        let persisted = try reactor.getPersistedSnapshot()

        #expect(throws: PersistenceError.machineMismatch(expected: "counter", actual: "other")) {
            try restoreSnapshot(machine: otherMachine, persisted: persisted)
        }
    }
}
