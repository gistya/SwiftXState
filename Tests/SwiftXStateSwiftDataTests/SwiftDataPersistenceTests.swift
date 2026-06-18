#if SWIFTXSTATE_APPLE_SWIFTDATA
import SwiftData
import Testing
@testable import SwiftXState
@testable import SwiftXStateSwiftData

private struct CartContext: Sendable, Equatable, Codable {
    var items: Int
}

@Suite("SwiftData reactor persistence")
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

    private func makeStore() throws -> ReactorPersistenceStore {
        let container = try withSwiftDataContainerLock {
            try ModelContainer(
                for: ReactorSnapshotRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        return ReactorPersistenceStore(modelContext: ModelContext(container))
    }

    @Test("saves and restores reactor snapshot from SwiftData")
    func saveAndRestore() throws {
        let store = try makeStore()
        let reactor = createReactor(cartMachine).start(context: CartContext(items: 0))
        reactor.send(Event("ADD"))
        reactor.send(Event("ADD"))

        try store.save(reactor, key: "session-1")

        let reloaded = try #require(try store.createReactor(cartMachine, key: "session-1"))

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
        let reactor = createReactor(cartMachine).start()
        try store.save(reactor, key: "temp")

        try store.delete(key: "temp")
        #expect(try store.load(key: "temp") == nil)
    }

    @Test("upsert overwrites existing snapshot")
    func upsert() throws {
        let store = try makeStore()
        let reactor = createReactor(cartMachine).start(context: CartContext(items: 0))

        reactor.send(Event("ADD"))
        try store.save(reactor, key: "cart")

        reactor.send(Event("ADD"))
        try store.save(reactor, key: "cart")

        let loaded = try store.load(key: "cart")
        let restored = try restoreSnapshot(machine: cartMachine, persisted: loaded!)
        #expect(restored.context.items == 2)
    }
}
#endif
