#if SWIFTXSTATE_APPLE_SWIFTDATA
import SwiftData
import Testing
@testable import SwiftXState
@testable import SwiftXStateSwiftData

private struct CartContext: Sendable, Equatable, Codable {
    var items: Int
}

@Suite("SwiftData actor persistence")
struct SwiftDataPersistenceTests {
    private var cartMachine: StateMachine<CartContext> {
        createMachine(MachineConfig(
            id: "cart",
            initial: "browsing",
            context: CartContext(items: 0),
            states: [
                "browsing": StateNodeConfig(on: [
                    "ADD": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.items += 1 }]
                    )),
                ]),
            ]
        ))
    }

    private func makeStore() throws -> ActorPersistenceStore {
        let container = try withSwiftDataContainerLock {
            try ModelContainer(
                for: ActorSnapshotRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        return ActorPersistenceStore(modelContext: ModelContext(container))
    }

    @Test("saves and restores actor snapshot from SwiftData")
    func saveAndRestore() throws {
        let store = try makeStore()
        let actor = createActor(cartMachine).start(context: CartContext(items: 0))
        actor.send(Event("ADD"))
        actor.send(Event("ADD"))

        try store.save(actor, key: "session-1")

        let reloaded = try #require(try store.createActor(cartMachine, key: "session-1"))

        #expect(reloaded.snapshot.context.items == 2)
        #expect(reloaded.snapshot.matches("browsing"))

        reloaded.send(Event("ADD"))
        #expect(reloaded.snapshot.context.items == 3)
    }

    @Test("load returns nil for missing key")
    func missingKey() throws {
        let store = try makeStore()
        #expect(try store.load(key: "missing") == nil)
    }

    @Test("delete removes persisted snapshot")
    func deleteSnapshot() throws {
        let store = try makeStore()
        let actor = createActor(cartMachine).start()
        try store.save(actor, key: "temp")

        try store.delete(key: "temp")
        #expect(try store.load(key: "temp") == nil)
    }

    @Test("upsert overwrites existing snapshot")
    func upsert() throws {
        let store = try makeStore()
        let actor = createActor(cartMachine).start(context: CartContext(items: 0))

        actor.send(Event("ADD"))
        try store.save(actor, key: "cart")

        actor.send(Event("ADD"))
        try store.save(actor, key: "cart")

        let loaded = try store.load(key: "cart")
        let restored = try restoreSnapshot(machine: cartMachine, persisted: loaded!)
        #expect(restored.context.items == 2)
    }
}
#endif