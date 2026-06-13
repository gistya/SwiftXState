#if SWIFTXSTATE_INSPECTOR_UI
import Foundation
import Observation
import SwiftXState
// Re-export the platform-neutral inspector core so every view file in this module (and consumers)
// sees ActorEntry, FeedEntry, the JSONValue tree helpers, MachineDefinitionImporter, and
// InspectorState without an extra import.
@_exported import SwiftXStateInspectorCore

/// SwiftUI-facing inspector store. A thin `@Observable` shell over the platform-neutral
/// `InspectorState` reducer (in `SwiftXStateInspectorCore`): all ingest/lookup logic lives there, so
/// this and the browser inspector can't drift apart. Mutating the single tracked `state` property
/// is what drives SwiftUI invalidation.
///
/// Plug `observe()` into any actor's `ActorOptions(inspect:)` (combine with other sinks as needed).
/// All ingestion hops to the main actor.
@MainActor
@Observable
public final class InspectorStore {
    /// The reducer holding all inspector state. Reassigned on every mutation, which is what SwiftUI
    /// observes — read any forwarded property below and the body subscribes to changes.
    public var state = InspectorState()

    public init() {}

    // MARK: Forwarded state (so existing call sites and bindings keep working)

    /// Actors in registration order.
    public var actors: [ActorEntry] { state.actors }
    /// Chronological event feed (oldest first), capped at `feedCap`.
    public var feed: [FeedEntry] { state.feed }
    /// Currently selected actor (drives the State/Events/Graph tabs).
    public var selectedSessionID: String? {
        get { state.selectedSessionID }
        set { state.selectedSessionID = newValue }
    }
    /// Maximum feed length; older entries are dropped.
    public var feedCap: Int {
        get { state.feedCap }
        set { state.feedCap = newValue }
    }

    // MARK: Ingestion

    /// Returns an inspect sink for `ActorOptions(inspect:)`. Safe to combine with others.
    public func observe() -> @Sendable (InspectionEvent) -> Void {
        { [weak self] event in
            Task { @MainActor in self?.ingest(event) }
        }
    }

    /// Ingest a single inspection event (already on the main actor).
    public func ingest(_ event: InspectionEvent) { state.ingest(event) }

    public func reset() { state.reset() }

    // MARK: Structural simulation (for pasted / static machines)

    func registerSimulator(_ simulator: MachineSimulator, for sessionID: String) {
        state.registerSimulator(simulator, for: sessionID)
    }

    public func isSimulatable(_ sessionID: String?) -> Bool { state.isSimulatable(sessionID) }

    public func availableEvents(for sessionID: String?) -> [String] { state.availableEvents(for: sessionID) }

    public func send(_ event: String, to sessionID: String) { state.send(event, to: sessionID) }

    /// Parse a pasted XState machine definition and load it as a fresh actor, selecting it.
    @discardableResult
    public func loadDefinition(json: String, fallbackID: String = "pasted-machine") throws -> String {
        try state.loadDefinition(json: json, fallbackID: fallbackID)
    }

    // MARK: Lookups

    public func actor(_ sessionID: String) -> ActorEntry? { state.actor(sessionID) }

    public var selectedActor: ActorEntry? { state.selectedActor }

    /// Feed filtered to a single actor (or all if `nil`).
    public func feed(for sessionID: String?) -> [FeedEntry] { state.feed(for: sessionID) }

    /// Direct children of an actor, in registration order.
    public func children(of sessionID: String) -> [ActorEntry] { state.children(of: sessionID) }

    /// Root actors (no known parent in the registry).
    public var rootActors: [ActorEntry] { state.rootActors }

    /// Flattened parent→child ordering with indentation depth, for the sidebar list.
    public func actorTree() -> [(actor: ActorEntry, depth: Int)] { state.actorTree() }
}
#endif
