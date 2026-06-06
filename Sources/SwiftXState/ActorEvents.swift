import Foundation

/// Event emitted when a nested state region reaches a final state.
public struct DoneStateEvent: Eventable {
    public let type: String
    public let stateId: String
    public let output: SendableValue?

    public init(stateId: String, output: SendableValue? = nil) {
        self.stateId = stateId
        self.type = createDoneStateEventType(stateId)
        self.output = output
    }
}

/// Event emitted when an invoked child actor reaches a final state.
public struct DoneActorEvent: Eventable {
    public let type: String
    public let actorId: String
    public let output: SendableValue?

    public init(actorId: String, output: SendableValue? = nil) {
        self.actorId = actorId
        self.type = createDoneActorEventType(actorId)
        self.output = output
    }
}

/// Event emitted when an invoked child actor fails.
public struct ErrorActorEvent: Eventable {
    public let type: String
    public let actorId: String
    public let error: String

    public init(actorId: String, error: String) {
        self.actorId = actorId
        self.type = createErrorActorEventType(actorId)
        self.error = error
    }
}

/// Event emitted when a child actor's snapshot changes (with `syncSnapshot`).
public struct SnapshotActorEvent: Eventable {
    public let type: String
    public let actorId: String
    public let snapshot: ChildActorSnapshot

    public init(actorId: String, snapshot: ChildActorSnapshot) {
        self.actorId = actorId
        self.type = createSnapshotActorEventType(actorId)
        self.snapshot = snapshot
    }
}

public func createDoneStateEventType(_ stateId: String) -> String {
    "xstate.done.state.\(stateId)"
}

public func createDoneActorEventType(_ actorId: String) -> String {
    "xstate.done.actor.\(actorId)"
}

public func createErrorActorEventType(_ actorId: String) -> String {
    "xstate.error.actor.\(actorId)"
}

public func createSnapshotActorEventType(_ actorId: String) -> String {
    "xstate.snapshot.\(actorId)"
}