#if SWIFTXSTATE_INSPECTOR_UI
import Testing
@testable import SwiftXState
@testable import SwiftXStateInspectorUI

@MainActor
@Suite("Inspector multi-actor (stress-test mechanism)")
struct InspectorMultiActorTests {
    /// A child machine each spawned actor runs.
    private func childMachine() -> ResolvedMachine<Int> {
        createMachine(MachineConfig<Int>(
            id: "square",
            initial: "empty",
            context: 0,
            states: [
                "empty": StateNodeConfig(on: ["OCCUPY": .to("occupied")]),
                "occupied": StateNodeConfig(on: ["CLEAR": .to("empty")]),
            ]
        ))
    }

    /// A parent that spawns N inspectable children on entry — the same mechanism the chess
    /// board uses for its 96 per-square/piece actors.
    private func parentMachine(childCount: Int) -> ResolvedMachine<Int> {
        let child = childMachine()
        var entries: [ActionRef<Int>] = []
        for i in 0..<childCount {
            entries.append(spawnChild(fromMachine(child, context: 0), id: "sq\(i)", systemId: "square", inspectable: true))
        }
        return createMachine(MachineConfig<Int>(
            id: "board",
            initial: "ready",
            context: 0,
            states: ["ready": StateNodeConfig(entry: entries)]
        ))
    }

    @Test("Inspectable child spawns all register in the store")
    func childrenRegister() async {
        let store = InspectorStore()
        // Children run on their own off-main executors, so their inspect events fire off-main too.
        // Capture the whole system's stream with a thread-safe collector, then replay into the
        // @MainActor store. `await start()` has fully spawned + started every child by the time it
        // returns, so the collector holds all registration events.
        let collector = InspectionCollector()
        let parent = parentMachine(childCount: 96)
        _ = await createActor(parent, options: ActorOptions(inspect: collector.observe())).start()

        for event in collector.recordedEvents() { store.ingest(event) }

        // Parent + 96 children all show up in the actor list.
        #expect(store.actors.count == 97)
        #expect(store.children(of: store.rootActors.first!.sessionID).count == 96)

        // The tree flattening produces one row per actor (drives the sidebar).
        #expect(store.actorTree().count == 97)
    }
}
#endif
