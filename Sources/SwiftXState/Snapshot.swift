import Foundation

/// The lifecycle status of a machine snapshot.
public enum SnapshotStatus: Sendable, Equatable, Codable {
    /// Running and able to receive events.
    case active
    /// Reached a top-level final state (may carry `output`).
    case done
    /// Stopped due to an error (see `snapshot.error`).
    case error
    /// Explicitly stopped.
    case stopped
}

/// A lightweight snapshot of a child actor tracked by a parent machine.
public struct ChildActorSnapshot: Sendable, Equatable {
    public let id: String
    public let status: SnapshotStatus
    public let value: String?
    public let error: String?

    public init(id: String, status: SnapshotStatus, value: String? = nil, error: String? = nil) {
        self.id = id
        self.status = status
        self.value = value
        self.error = error
    }
}

/// A point-in-time snapshot of a running machine — the value you read after each transition
/// (`actor.snapshot`). Test it with `matches(_:)` / `hasTag(_:)` / `can(_:)` and read `context`.
public struct MachineSnapshot<Context: Sendable>: Sendable {
    /// The machine this snapshot belongs to.
    public let machine: StateMachine<Context>
    /// The active state value (e.g. `.atomic("green")` or `.compound(["red": .atomic("wait")])`).
    public let value: StateValue
    /// The current context.
    public let context: Context
    /// Tags active in the current configuration.
    public let tags: Set<String>
    /// Lifecycle status.
    public let status: SnapshotStatus
    /// Output produced when the machine reached a final state (`status == .done`).
    public let output: SendableValue?
    /// Error that stopped the machine (`status == .error`).
    public let error: SendableValue?
    /// Snapshots of invoked/spawned child actors, keyed by id.
    public let children: [String: ChildActorSnapshot]
    let _nodes: [StateNode<Context>]
    let historyValue: HistoryValue<Context>

    init(
        machine: StateMachine<Context>,
        value: StateValue,
        context: Context,
        nodes: [StateNode<Context>],
        tags: Set<String>,
        status: SnapshotStatus,
        historyValue: HistoryValue<Context> = HistoryValue(),
        output: SendableValue? = nil,
        error: SendableValue? = nil,
        children: [String: ChildActorSnapshot] = [:]
    ) {
        self.machine = machine
        self.value = value
        self.context = context
        self._nodes = nodes
        self.tags = tags
        self.status = status
        self.historyValue = historyValue
        self.output = output
        self.error = error
        self.children = children
    }

    /// Whether the current state value matches the given partial state value.
    public func matches(_ partial: StateValue) -> Bool {
        value.matches(partial)
    }

    /// Whether the current state value matches a string path.
    public func matches(_ path: String) -> Bool {
        value.matches(path)
    }

    /// Whether the current state has the given tag.
    public func hasTag(_ tag: String) -> Bool {
        tags.contains(tag)
    }

    /// Meta objects for active configuration nodes that define `meta`, keyed by state node id.
    ///
    /// Mirrors XState's `snapshot.getMeta()` — e.g. `["traffic.light.green": ["color": "green"]]`.
    public func getMeta() -> [String: [String: SendableValue]] {
        var result: [String: [String: SendableValue]] = [:]
        for node in _nodes {
            if let meta = node.meta {
                result[node.id] = meta
            }
        }
        return result
    }

    /// Whether sending the event would cause a transition.
    public func can(_ event: any Eventable) -> Bool {
        !selectTransitions(event: event, snapshot: self).isEmpty
    }
}