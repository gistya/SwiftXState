#if SWIFTXSTATE_APPLE_SWIFTDATA
import SwiftData
import Testing
@testable import SwiftXState
@testable import SwiftXStateSwiftData

private struct ReplayPersistContext: Sendable, Equatable, Codable {
    var count: Int
}

@Suite("SwiftData replay session persistence")
struct ReplaySwiftDataTests {
    private var counterMachine: StateMachine<ReplayPersistContext> {
        createMachine(MachineConfig(
            id: "counter",
            initial: "idle",
            context: ReplayPersistContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                    "GO": .to("done"),
                ]),
                "done": StateNodeConfig(type: .final),
            ]
        ))
    }

    private func makeStore() throws -> ReplayPersistenceStore {
        let container = try withSwiftDataContainerLock {
            try ModelContainer(
                for: ReplaySessionRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        return ReplayPersistenceStore(modelContext: ModelContext(container))
    }

    private func recordSession() async -> (InspectionRecorder, ReplaySession) {
        let recorder = InspectionRecorder()
        let actor = await createActor(
            counterMachine,
            options: ActorOptions(inspect: recorder.observe())
        ).start(context: ReplayPersistContext(count: 0))

        await actor.send(Event("INC"))
        await actor.send(Event("GO"))

        guard let session = recorder.session() else {
            fatalError("Expected recorded session")
        }
        return (recorder, session)
    }

    @Test("saves and loads replay session from SwiftData")
    func saveAndLoad() async throws {
        let store = try makeStore()
        let (_, session) = await recordSession()

        try store.save(session, key: "run-1")
        let loaded = try store.load(key: "run-1")

        #expect(loaded != nil)
        #expect(loaded?.steps.count == session.steps.count)
        #expect(loaded?.finalSnapshot?.value == "done")
        #expect(loaded?.replayEvents.count == 2)
    }

    @Test("save recorder persists current session")
    func saveFromRecorder() async throws {
        let store = try makeStore()
        let (recorder, _) = await recordSession()

        try store.save(recorder, key: "run-2")
        let loaded = try store.load(key: "run-2")

        #expect(loaded?.machineId == "counter")
        #expect(loaded?.steps.count == 3)
    }

    @Test("loaded session replays on live actor")
    func replayAfterLoad() async throws {
        let store = try makeStore()
        let (_, session) = await recordSession()
        try store.save(session, key: "run-3")

        let loaded = try store.load(key: "run-3")!
        let (actor, verifications) = await replayActor(
            counterMachine,
            context: ReplayPersistContext(count: 0),
            session: loaded
        )

        #expect(verifications.filter { !$0.matches }.isEmpty)
        let snapshot = await actor.snapshot
        #expect(snapshot.matches("done"))
        #expect(snapshot.context.count == 1)
    }

    @Test("delete removes stored replay session")
    func deleteSession() async throws {
        let store = try makeStore()
        let (_, session) = await recordSession()
        try store.save(session, key: "temp")

        try store.delete(key: "temp")
        #expect(try store.load(key: "temp") == nil)
    }

    @Test("save throws when recorder is empty")
    func emptyRecorder() throws {
        let store = try makeStore()
        let recorder = InspectionRecorder()

        #expect(throws: ReplayPersistenceError.noRecordedSession) {
            try store.save(recorder, key: "empty")
        }
    }
}
#endif
