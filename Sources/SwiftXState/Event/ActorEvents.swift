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

/// Event emitted when an invoked child reactor reaches a final state.
public struct DoneReactorEvent: Eventable {
    public let type: String
    public let reactorId: String
    public let output: SendableValue?

    public init(reactorId: String, output: SendableValue? = nil) {
        self.reactorId = reactorId
        self.type = createDoneReactorEventType(reactorId)
        self.output = output
    }
}

/// Event emitted when an invoked child reactor fails.
public struct ErrorReactorEvent: Eventable {
    public let type: String
    public let reactorId: String
    public let error: String

    public init(reactorId: String, error: String) {
        self.reactorId = reactorId
        self.type = createErrorReactorEventType(reactorId)
        self.error = error
    }
}

/// Event emitted when a child reactor's snapshot changes (with `syncSnapshot`).
public struct SnapshotReactorEvent: Eventable {
    public let type: String
    public let reactorId: String
    public let snapshot: ChildReactorSnapshot

    public init(reactorId: String, snapshot: ChildReactorSnapshot) {
        self.reactorId = reactorId
        self.type = createSnapshotReactorEventType(reactorId)
        self.snapshot = snapshot
    }
}

public func createDoneStateEventType(_ stateId: String) -> String {
    "xstate.done.state.\(stateId)"
}

public func createDoneReactorEventType(_ reactorId: String) -> String {
    "xstate.done.reactor.\(reactorId)"
}

public func createErrorReactorEventType(_ reactorId: String) -> String {
    "xstate.error.reactor.\(reactorId)"
}

public func createSnapshotReactorEventType(_ reactorId: String) -> String {
    "xstate.snapshot.\(reactorId)"
}
