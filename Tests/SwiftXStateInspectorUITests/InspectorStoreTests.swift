#if SWIFTXSTATE_INSPECTOR_UI
import Testing
@testable import SwiftXState
@testable import SwiftXStateInspectorUI

@MainActor
@Suite("InspectorStore ingestion")
struct InspectorStoreTests {
    private func makeMachine() -> StateMachine<Int> {
        createMachine(MachineConfig<Int>(
            id: "lights",
            initial: "green",
            context: 0,
            states: [
                "green": StateNodeConfig(on: ["NEXT": .to("yellow")]),
                "yellow": StateNodeConfig(on: ["NEXT": .to("red")]),
                "red": StateNodeConfig(on: ["NEXT": .to("green")]),
            ]
        ))
    }

    @Test("Registers actors and tracks live snapshots from the real stream")
    func ingestsLiveStream() async {
        let store = InspectorStore()
        // `Actor` runs on its own (off-main) executor, so its inspect events fire off-main. Capture
        // them with a thread-safe collector and replay into the @MainActor store here on the test's
        // main actor — the same shape as InspectorStore.observe() without the Task-hop timing.
        let collector = InspectionCollector()
        let machine = makeMachine()
        let actor = await createActor(machine, options: ActorOptions(inspect: collector.observe())).start()
        let actorID = actor.sessionId

        for event in collector.recordedEvents() { store.ingest(event) }
        collector.reset()

        // One actor registered, with its definition (so the inspector can graph it).
        #expect(store.actors.count == 1)
        let entry = store.actor(actorID)
        #expect(entry != nil)
        #expect(entry?.definitionJSON != nil)
        #expect(store.selectedSessionID == actorID)

        // Initial snapshot tracked.
        #expect(entry?.stateValue?.matches("green") == true)

        await actor.send(Event("NEXT"))
        for event in collector.recordedEvents() { store.ingest(event) }

        #expect(store.actor(actorID)?.stateValue?.matches("yellow") == true)
        #expect(store.actor(actorID)?.lastEventType == "NEXT")

        // Feed accumulated event + snapshot rows.
        #expect(store.feed.contains { $0.kind == .actor })
        #expect(store.feed.contains { $0.kind == .event && $0.eventType == "NEXT" })
        #expect(store.feed.contains { $0.kind == .snapshot })
    }

    @Test("Feed respects the cap")
    func feedCap() {
        let store = InspectorStore()
        store.feedCap = 10
        let ref = InspectionActorRef(sessionId: "s1", machineId: "m")
        for _ in 0..<50 {
            store.ingest(InspectionEvent(kind: .event, rootId: "s1", actor: ref, event: .init(type: "PING")))
        }
        #expect(store.feed.count == 10)
    }

    @Test("Raw inspection event re-encodes to a JSON tree")
    func rawJSON() {
        let ref = InspectionActorRef(sessionId: "s1", machineId: "m")
        let event = InspectionEvent(kind: .event, rootId: "s1", actor: ref, event: .init(type: "TAP"))
        let json = event.inspectorJSONValue()
        #expect(json.kind == .object)
        #expect(json.isExpandable)
    }
}
#endif
