#if SWIFTXSTATE_INSPECTOR_UI
import Foundation
import Observation
import SwiftXState

/// Consumes the in-process `InspectionEvent` stream and maintains everything the inspector
/// UI shows: the live actor registry, a capped chronological event feed, and the current
/// selection. Plug `observe()` into any actor's `ActorOptions(inspect:)` (combine with other
/// sinks as needed). All ingestion hops to the main actor.
@MainActor
@Observable
public final class InspectorStore {
    /// Actors in registration order.
    public private(set) var actors: [ActorEntry] = []
    /// Chronological event feed (oldest first), capped at `feedCap`.
    public private(set) var feed: [FeedEntry] = []
    public var selectedSessionID: String?
    /// Maximum feed length; older entries are dropped.
    public var feedCap: Int = 2000

    private var actorIndex: [String: Int] = [:]
    private var seq = 0
    private var registrationOrder = 0
    /// Structural simulators for statically-loaded (pasted) machines, keyed by session id.
    /// Live actors have no simulator (they're driven by their real runtime).
    @ObservationIgnored private var simulators: [String: MachineSimulator] = [:]

    public init() {}

    /// Returns an inspect sink for `ActorOptions(inspect:)`. Safe to combine with others.
    public func observe() -> @Sendable (InspectionEvent) -> Void {
        { [weak self] event in
            Task { @MainActor in self?.ingest(event) }
        }
    }

    /// Ingest a single inspection event (already on the main actor).
    public func ingest(_ event: InspectionEvent) {
        upsertActor(from: event)

        seq += 1
        feed.append(FeedEntry(id: seq, event: event))
        if feed.count > feedCap {
            feed.removeFirst(feed.count - feedCap)
        }

        if selectedSessionID == nil {
            selectedSessionID = actors.first?.sessionID
        }
    }

    public func reset() {
        actors.removeAll()
        feed.removeAll()
        actorIndex.removeAll()
        simulators.removeAll()
        selectedSessionID = nil
        seq = 0
        registrationOrder = 0
    }

    // MARK: Structural simulation (for pasted / static machines)

    /// Attach a structural simulator to an actor so the UI can drive it.
    func registerSimulator(_ simulator: MachineSimulator, for sessionID: String) {
        simulators[sessionID] = simulator
    }

    /// Whether the actor can be driven by structural simulation (i.e. was loaded statically).
    public func isSimulatable(_ sessionID: String?) -> Bool {
        guard let sessionID else { return false }
        return simulators[sessionID] != nil
    }

    /// Events sendable from the actor's current state (empty for live, non-simulatable actors).
    public func availableEvents(for sessionID: String?) -> [String] {
        guard let sessionID, let simulator = simulators[sessionID],
              let value = actor(sessionID)?.stateValue else { return [] }
        return simulator.availableEvents(from: value)
    }

    /// Send an event to a simulated actor: advances its state and appends synthetic event +
    /// snapshot rows to the feed (so Events/Sequence light up). No-op for live actors or events
    /// the current state can't handle.
    public func send(_ event: String, to sessionID: String) {
        guard let simulator = simulators[sessionID],
              let entry = actor(sessionID),
              let current = entry.stateValue,
              let next = simulator.step(from: current, event: event) else { return }

        let ref = InspectionActorRef(sessionId: entry.sessionID, systemId: entry.systemID, machineId: entry.machineID)
        ingest(InspectionEvent(
            kind: .event, rootId: entry.sessionID, actor: ref,
            event: InspectionEventDescription(type: event)
        ))
        let snapshot = InspectionSnapshot(
            actor: ref, status: .active, value: next.description,
            stateValue: next, tags: [], childCount: 0,
            context: entry.contextJSON ?? .object([:])
        )
        ingest(InspectionEvent(kind: .snapshot, rootId: entry.sessionID, actor: ref, snapshot: snapshot))
    }

    // MARK: Lookups

    public func actor(_ sessionID: String) -> ActorEntry? {
        actorIndex[sessionID].map { actors[$0] }
    }

    public var selectedActor: ActorEntry? {
        selectedSessionID.flatMap(actor)
    }

    /// Feed filtered to a single actor (or all if `nil`).
    public func feed(for sessionID: String?) -> [FeedEntry] {
        guard let sessionID else { return feed }
        return feed.filter { $0.sessionID == sessionID || $0.sourceSessionID == sessionID }
    }

    /// Direct children of an actor, in registration order.
    public func children(of sessionID: String) -> [ActorEntry] {
        actors.filter { $0.parentSessionID == sessionID }
    }

    /// Root actors (no known parent in the registry).
    public var rootActors: [ActorEntry] {
        actors.filter { entry in
            guard let parent = entry.parentSessionID else { return true }
            return actorIndex[parent] == nil
        }
    }

    /// Flattened parent→child ordering with indentation depth, for the sidebar list.
    public func actorTree() -> [(actor: ActorEntry, depth: Int)] {
        var out: [(ActorEntry, Int)] = []
        func visit(_ entry: ActorEntry, depth: Int) {
            out.append((entry, depth))
            for child in children(of: entry.sessionID) {
                visit(child, depth: depth + 1)
            }
        }
        for root in rootActors { visit(root, depth: 0) }
        return out
    }

    // MARK: Ingestion

    private func upsertActor(from event: InspectionEvent) {
        let ref = event.actor
        var entry: ActorEntry
        if let idx = actorIndex[ref.sessionID] {
            entry = actors[idx]
        } else {
            registrationOrder += 1
            entry = ActorEntry(sessionID: ref.sessionID, order: registrationOrder)
        }

        if let machineID = ref.machineID { entry.machineID = machineID }
        if let systemID = ref.systemID { entry.systemID = systemID }
        if let parent = event.parentSessionId { entry.parentSessionID = parent }
        if let def = event.definitionJSON { entry.definitionJSON = def }
        if let snapshot = event.snapshot {
            entry.latestSnapshot = snapshot
            entry.status = snapshot.status
        }
        if event.kind == .event, let type = event.event?.type {
            entry.lastEventType = type
        }

        if let idx = actorIndex[ref.sessionID] {
            actors[idx] = entry
        } else {
            actorIndex[ref.sessionID] = actors.count
            actors.append(entry)
        }
    }
}

extension InspectionActorRef {
    var machineID: String? { machineId }
    var systemID: String? { systemId }
}
#endif
