import Foundation
import SwiftXState

/// A tracked actor, accumulated from the inspection stream. One per `sessionId`.
public struct ActorEntry: Identifiable, Sendable {
    public let sessionID: String
    public var machineID: String?
    public var systemID: String?
    public var parentSessionID: String?
    /// XState-compatible machine definition (from the `.actor` registration event), used to graph it.
    public var definitionJSON: String?
    /// Most recent snapshot seen for this actor (state value, context, status, …).
    public var latestSnapshot: InspectionSnapshot?
    public var lastEventType: String?
    public var status: SnapshotStatus = .active
    /// Monotonic registration order, for stable list sorting.
    public var order: Int

    public init(sessionID: String, order: Int) {
        self.sessionID = sessionID
        self.order = order
    }

    public var id: String { sessionID }

    /// Friendly name shown in the actor list (`game-watcher`, `opening-move-tree`, …).
    public var displayName: String { machineID ?? systemID ?? sessionID }
    /// Secondary identifier shown in parentheses.
    public var subtitle: String { systemID ?? sessionID }

    /// Current state value (for the state pill, graph highlighting, and the value tree).
    public var stateValue: StateValue? { latestSnapshot?.stateValue }
    public var contextJSON: JSONValue? { latestSnapshot?.context }
}

/// A single row in the chronological event feed — a thin wrapper over an `InspectionEvent`.
public struct FeedEntry: Identifiable, Sendable {
    public let id: Int
    public let event: InspectionEvent

    public init(id: Int, event: InspectionEvent) {
        self.id = id
        self.event = event
    }

    public var kind: InspectionEventKind { event.kind }
    public var timestamp: TimeInterval { event.timestamp }
    public var sessionID: String { event.actor.sessionID }
    public var sourceSessionID: String? { event.source?.sessionID }
    public var eventType: String? { event.event?.type }
    public var snapshot: InspectionSnapshot? { event.snapshot }
}

public extension InspectionActorRef {
    var sessionID: String { sessionId }
    var machineID: String? { machineId }
    var systemID: String? { systemId }
}

// MARK: - Encodable -> JSONValue (for the raw "inspection event" disclosure)

public extension Encodable {
    /// Re-encodes any Codable value into the inspector's `JSONValue` tree for display.
    func inspectorJSONValue() -> JSONValue {
        guard let data = try? JSONEncoder().encode(self),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return value
    }
}
