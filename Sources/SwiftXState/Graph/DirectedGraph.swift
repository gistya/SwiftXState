import Foundation

// MARK: - Traversal options

/// Knobs for graph traversal / path generation — the Swift analogue of `@xstate/graph`'s
/// `TraversalOptions`.
public struct TraversalOptions<Context: Sendable>: Sendable {
    /// Candidate events to attempt from each state. Defaults to one `Event(type)` per
    /// `machine.events` (every declared event type, with no payload).
    public var events: [any Eventable]?

    /// Resolve candidate events from a snapshot. Overrides `events` when set — use this for
    /// payload-carrying events whose values depend on the current state/context.
    public var eventResolver: (@Sendable (MachineSnapshot<Context>) -> [any Eventable])?

    /// Serialize a snapshot to a de-duplication key. Defaults to the state value's description,
    /// so distinct contexts under the same state value collapse to one node. Supply a
    /// context-aware serializer to distinguish them (and keep it finite to bound traversal).
    public var serializeState: (@Sendable (MachineSnapshot<Context>) -> String)?

    /// Serialize an event to a per-source de-duplication key. Defaults to `event.type`.
    public var serializeEvent: (@Sendable (any Eventable) -> String)?

    /// Safety cap on the number of distinct states explored.
    public var maxStates: Int

    public init(
        events: [any Eventable]? = nil,
        eventResolver: (@Sendable (MachineSnapshot<Context>) -> [any Eventable])? = nil,
        serializeState: (@Sendable (MachineSnapshot<Context>) -> String)? = nil,
        serializeEvent: (@Sendable (any Eventable) -> String)? = nil,
        maxStates: Int = 10_000
    ) {
        self.events = events
        self.eventResolver = eventResolver
        self.serializeState = serializeState
        self.serializeEvent = serializeEvent
        self.maxStates = maxStates
    }

    func key(_ snapshot: MachineSnapshot<Context>) -> String {
        serializeState?(snapshot) ?? snapshot.value.description
    }

    func eventKey(_ event: any Eventable) -> String {
        serializeEvent?(event) ?? event.type
    }

    func candidates(_ machine: StateMachine<Context>, _ snapshot: MachineSnapshot<Context>) -> [any Eventable] {
        if let eventResolver { return eventResolver(snapshot) }
        if let events { return events }
        return machine.events.map { Event($0) }
    }
}

// MARK: - Adjacency map

/// One outgoing transition discovered during traversal.
public struct AdjacencyEdge<Context: Sendable>: Sendable {
    public let event: any Eventable
    public let nextStateKey: String
    public let nextSnapshot: MachineSnapshot<Context>
}

/// A reachable state and the transitions leaving it.
public struct AdjacencyEntry<Context: Sendable>: Sendable {
    public let stateKey: String
    public let snapshot: MachineSnapshot<Context>
    public let edges: [AdjacencyEdge<Context>]
}

/// The behavior graph of a machine: every reachable state keyed by its serialized value, with the
/// event-labeled edges between them. Built faithfully via the core `transition` function, so guards
/// are evaluated and `assign` updates are applied as states are explored.
///
/// Mirrors `@xstate/graph`'s `getAdjacencyMap`.
public func getAdjacencyMap<Context: Sendable>(
    _ machine: StateMachine<Context>,
    options: TraversalOptions<Context> = .init()
) -> [String: AdjacencyEntry<Context>] {
    let initial = initialTransition(machine).snapshot
    var map: [String: AdjacencyEntry<Context>] = [:]
    var enqueued: Set<String> = []

    var queue: [MachineSnapshot<Context>] = [initial]
    enqueued.insert(options.key(initial))
    var head = 0

    while head < queue.count {
        let snapshot = queue[head]; head += 1
        let stateKey = options.key(snapshot)

        var edges: [AdjacencyEdge<Context>] = []
        var seenEventKeys: Set<String> = []
        for event in options.candidates(machine, snapshot) {
            guard snapshot.can(event) else { continue }
            guard seenEventKeys.insert(options.eventKey(event)).inserted else { continue }
            let next = transition(machine, snapshot: snapshot, event: event).snapshot
            let nextKey = options.key(next)
            edges.append(AdjacencyEdge(event: event, nextStateKey: nextKey, nextSnapshot: next))
            if !enqueued.contains(nextKey), map.count + queue.count < options.maxStates {
                enqueued.insert(nextKey)
                queue.append(next)
            }
        }
        map[stateKey] = AdjacencyEntry(stateKey: stateKey, snapshot: snapshot, edges: edges)
        if map.count >= options.maxStates { break }
    }
    return map
}
