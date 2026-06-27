import Foundation
import Testing
@testable import SwiftXState

private struct PersistCounterContext: Sendable, Equatable, Codable {
    var count: Int
}

@Suite("Actor persistence")
struct PersistenceTests {
    private var counterMachine: ResolvedMachine<PersistCounterContext> {
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
    func roundTrip() async throws {
        let machine = counterMachine
        let actor = await createActor(machine).start(context: PersistCounterContext(count: 0))
        await actor.send(Event("INC"))
        await actor.send(Event("INC"))

        let persisted = try await actor.getPersistedSnapshot()
        let restored = try restoreSnapshot(machine: machine, persisted: persisted)

        #expect(await restored.value == actor.snapshot.value)
        #expect(restored.context.count == 2)
        #expect(restored.matches("idle"))
        #expect(await restored.tags == actor.snapshot.tags)
    }

    @Test("actor starts from persisted snapshot and continues transitioning")
    func startFromPersisted() async throws {
        let machine = counterMachine
        let original = await createActor(machine).start(context: PersistCounterContext(count: 0))
        await original.send(Event("INC"))
        let persisted = try await original.getPersistedSnapshot()

        let restoredActor = await createActor(machine).start(from: persisted)

        #expect(await restoredActor.snapshot.context.count == 1)
        #expect(await restoredActor.snapshot.matches("idle"))

        await restoredActor.send(Event("INC"))
        await restoredActor.send(Event("DONE"))

        #expect(await restoredActor.snapshot.matches("finished"))
        #expect(await restoredActor.snapshot.context.count == 2)
        #expect(await restoredActor.snapshot.status == .done)
    }

    @Test("createActor with snapshot hydrates in one step")
    func createActorWithSnapshot() async throws {
        let machine = counterMachine
        let original = await createActor(machine).start(context: PersistCounterContext(count: 0))
        await original.send(Event("INC"))
        await original.send(Event("INC"))
        let persisted = try await original.getPersistedSnapshot()

        let restoredActor = await createActor(machine, snapshot: persisted)

        #expect(await restoredActor.snapshot.context.count == 2)
        #expect(await restoredActor.snapshot.matches("idle"))
        #expect(await restoredActor.snapshot.status == .active)

        await restoredActor.send(Event("DONE"))
        #expect(await restoredActor.snapshot.matches("finished"))
        #expect(await restoredActor.snapshot.status == .done)
    }

    @Test("createActor with snapshot accepts context override")
    func createActorWithSnapshotContextOverride() async throws {
        let machine = counterMachine
        let original = await createActor(machine).start(context: PersistCounterContext(count: 0))
        await original.send(Event("INC"))
        let persisted = try await original.getPersistedSnapshot()

        let restoredActor = await createActor(
            machine,
            snapshot: persisted,
            context: PersistCounterContext(count: 99)
        )

        #expect(await restoredActor.snapshot.context.count == 99)
        #expect(await restoredActor.snapshot.matches("idle"))
    }

    @Test("persisted JSON survives encode and decode")
    func jsonRoundTrip() async throws {
        let actor = await createActor(counterMachine).start(context: PersistCounterContext(count: 3))
        await actor.send(Event("INC"))

        let persisted = try await actor.getPersistedSnapshot()
        let data = try persisted.encodeJSON()
        let decoded = try PersistedSnapshot.decodeJSON(data)

        let restored = try restoreSnapshot(machine: counterMachine, persisted: decoded)
        #expect(restored.context.count == 4)
    }

    @Test("persisted snapshot includes invoked child machine state")
    func childMachinePersistence() async throws {
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
                            src: .machine(MachineActorLogicBox(childMachine))
                        ),
                    ]
                ),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        await actor.send(Event("GO"))
        await actor.childActor(id: "worker")?.send(Event("INC"))
        await actor.childActor(id: "worker")?.send(Event("INC"))

        let persisted = try await actor.getPersistedSnapshot()
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

        let restored = await createActor(parentMachine).start(from: persisted)
        guard let child = await restored.childActor(id: "worker") as? LogicChildActor<MachineLogic<WorkerContext>> else {
            Issue.record("Expected restored machine child")
            return
        }

        #expect(await child.actor.snapshot.context.count == 2)
        #expect(await restored.snapshot.matches("working"))
    }

    @Test("backward compatible persisted JSON without children field")
    func legacyPersistedJSON() async throws {
        let actor = await createActor(counterMachine).start(context: PersistCounterContext(count: 1))
        let persisted = try await actor.getPersistedSnapshot()
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
    func nestedGrandchildPersistence() async throws {
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
                            src: .machine(MachineActorLogicBox(leafMachine))
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
                            src: .machine(MachineActorLogicBox(midMachine))
                        ),
                    ]
                ),
            ]
        ))

        let actor = await createActor(rootMachine).start()
        await actor.send(Event("GO"))
        guard let midChild = await actor.childActor(id: "mid") as? LogicChildActor<MachineLogic<MidContext>> else {
            Issue.record("Expected mid child actor")
            return
        }
        await midChild.send(Event("GO"))
        await midChild.actor.childActor(id: "leaf")?.send(Event("INC"))
        await midChild.actor.childActor(id: "leaf")?.send(Event("INC"))
        await midChild.actor.childActor(id: "leaf")?.send(Event("INC"))

        let persisted = try await actor.getPersistedSnapshot()
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

        let restored = await createActor(rootMachine).start(from: persisted)
        guard let mid = await restored.childActor(id: "mid") as? LogicChildActor<MachineLogic<MidContext>>,
              let leaf = await mid.actor.childActor(id: "leaf") as? LogicChildActor<MachineLogic<LeafContext>> else {
            Issue.record("Expected restored nested machine children")
            return
        }
        
        let actor2 = mid.actor
        #expect(await actor2.snapshot.matches("working"))
        #expect(await leaf.actor.snapshot.context.count == 3)
    }

    @Test("persisted snapshot restores multiple parallel invoked children")
    func parallelInvokePersistence() async throws {
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
                            src: .machine(MachineActorLogicBox(workerAMachine))
                        ),
                    ]
                ),
                "regionB": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "workerB",
                            src: .machine(MachineActorLogicBox(workerBMachine))
                        ),
                    ]
                ),
            ],
            type: .parallel
        ))

        let actor = await createActor(parentMachine).start()
        await actor.childActor(id: "workerA")?.send(Event("INC"))
        await actor.childActor(id: "workerB")?.send(Event("INC"))
        await actor.childActor(id: "workerB")?.send(Event("INC"))

        let persisted = try await actor.getPersistedSnapshot()
        let restored = await createActor(parentMachine).start(from: persisted)

        guard let workerA = await restored.childActor(id: "workerA") as? LogicChildActor<MachineLogic<WorkerContext>>,
              let workerB = await restored.childActor(id: "workerB") as? LogicChildActor<MachineLogic<WorkerContext>> else {
            Issue.record("Expected restored parallel machine children")
            return
        }

        #expect(await workerA.actor.snapshot.context.count == 1)
        #expect(await workerB.actor.snapshot.context.count == 4)
    }

    @Test("spawned machine child state survives persist and restore")
    func spawnedMachineChildPersistence() async throws {
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
                            src: .machine(MachineActorLogicBox(childMachine)),
                            id: "spawnedWorker"
                        )),
                    ]
                ),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        await actor.childActor(id: "spawnedWorker")?.send(Event("INC"))
        await actor.childActor(id: "spawnedWorker")?.send(Event("INC"))

        let persisted = try await actor.getPersistedSnapshot()
        let restored = await createActor(parentMachine).start(from: persisted)

        guard let child = await restored.childActor(id: "spawnedWorker") as? LogicChildActor<MachineLogic<ChildContext>> else {
            Issue.record("Expected restored spawned machine child")
            return
        }

        #expect(await child.actor.snapshot.context.count == 2)
    }

    @Test("restoring done child does not re-emit DoneActorEvent")
    func restoredDoneChildDoesNotReemit() async throws {
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
                        createDoneActorEventType("worker"): .single(TransitionConfig(
                            actions: [assign { ctx, _ in ctx.doneCount += 1 }]
                        )),
                    ],
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: .machine(MachineActorLogicBox(childMachine))
                        ),
                    ]
                ),
            ]
        ))

        let actor = await createActor(parentMachine).start()
        await actor.send(Event("GO"))
        await actor.waitForSnapshot { $0.context.doneCount == 1 }
        #expect(await actor.snapshot.context.doneCount == 1)

        let persisted = try await actor.getPersistedSnapshot()
        let restored = await createActor(parentMachine).start(from: persisted)

        #expect(await restored.snapshot.context.doneCount == 1)
        #expect(await restored.snapshot.matches("working"))
    }

    @Test("persisted snapshot records opaque task child status")
    func opaqueTaskChildPersistence() async throws {
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

        let actor = await createActor(parentMachine).start()
        await actor.send(Event("GO"))

        let activePersisted = try await actor.getPersistedSnapshot()
        if case let .opaque(opaque) = activePersisted.children["task"] {
            #expect(opaque.status == .active)
        } else {
            Issue.record("Expected opaque active task child snapshot")
        }
    }

    @Test("rejects machine mismatch on restore")
    func machineMismatch() async throws {
        let otherMachine = createMachine(MachineConfig(
            id: "other",
            initial: "idle",
            context: PersistCounterContext(count: 0),
            states: ["idle": StateNodeConfig()]
        ))

        let actor = await createActor(counterMachine).start()
        let persisted = try await actor.getPersistedSnapshot()

        #expect(throws: PersistenceError.machineMismatch(expected: "counter", actual: "other")) {
            try restoreSnapshot(machine: otherMachine, persisted: persisted)
        }
    }
}
