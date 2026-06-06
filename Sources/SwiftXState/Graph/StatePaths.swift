import Foundation

/// One step along a path: an event and the snapshot reached *after* applying it.
public struct PathStep<Context: Sendable>: Sendable {
    public let event: any Eventable
    public let snapshot: MachineSnapshot<Context>

    public init(event: any Eventable, snapshot: MachineSnapshot<Context>) {
        self.event = event
        self.snapshot = snapshot
    }
}

/// A path from the machine's initial state to a target state, as a sequence of event steps.
/// Mirrors `@xstate/graph`'s `StatePath`.
public struct StatePath<Context: Sendable>: Sendable {
    /// The target snapshot (the state this path ends in).
    public let state: MachineSnapshot<Context>
    /// The ordered steps from the initial state to `state`. Empty for the initial state itself.
    public let steps: [PathStep<Context>]

    public init(state: MachineSnapshot<Context>, steps: [PathStep<Context>]) {
        self.state = state
        self.steps = steps
    }

    /// Number of events in the path.
    public var weight: Int { steps.count }

    /// A readable `"-EVENT-> b -EVENT-> c"` rendering, using event types and the state value
    /// reached after each step. (The starting value isn't stored on the path; inspect the step
    /// snapshots directly if you need it.)
    public var description: String {
        guard !steps.isEmpty else { return state.value.description }
        return steps
            .map { "-\($0.event.type)-> \($0.snapshot.value.description)" }
            .joined(separator: " ")
    }
}

/// Shortest paths from the initial state to every reachable state (one per state, BFS order).
/// Mirrors `@xstate/graph`'s `getShortestPaths`.
public func getShortestPaths<Context: Sendable>(
    _ machine: StateMachine<Context>,
    options: TraversalOptions<Context> = .init()
) -> [StatePath<Context>] {
    let map = getAdjacencyMap(machine, options: options)
    let initial = initialTransition(machine).snapshot
    let initialKey = options.key(initial)
    guard map[initialKey] != nil else { return [] }

    var predecessor: [String: (from: String, edge: AdjacencyEdge<Context>)] = [:]
    var visited: Set<String> = [initialKey]
    var order: [String] = []
    var queue = [initialKey]; var head = 0

    while head < queue.count {
        let current = queue[head]; head += 1
        order.append(current)
        for edge in map[current]?.edges ?? [] where !visited.contains(edge.nextStateKey) {
            visited.insert(edge.nextStateKey)
            predecessor[edge.nextStateKey] = (current, edge)
            queue.append(edge.nextStateKey)
        }
    }

    func path(to key: String) -> StatePath<Context> {
        var steps: [PathStep<Context>] = []
        var cursor = key
        while let p = predecessor[cursor] {
            steps.insert(PathStep(event: p.edge.event, snapshot: p.edge.nextSnapshot), at: 0)
            cursor = p.from
        }
        return StatePath(state: map[key]!.snapshot, steps: steps)
    }

    return order.map(path(to:))
}

/// All *simple* (acyclic) paths from the initial state to every reachable state.
/// Mirrors `@xstate/graph`'s `getSimplePaths`.
///
/// - Parameter maxPaths: safety cap on the number of paths collected (dense graphs can have an
///   exponential number of simple paths).
public func getSimplePaths<Context: Sendable>(
    _ machine: StateMachine<Context>,
    options: TraversalOptions<Context> = .init(),
    maxPaths: Int = 10_000
) -> [StatePath<Context>] {
    let map = getAdjacencyMap(machine, options: options)
    let initial = initialTransition(machine).snapshot
    let initialKey = options.key(initial)
    guard let initialEntry = map[initialKey] else { return [] }

    var results: [StatePath<Context>] = []

    func dfs(_ entry: AdjacencyEntry<Context>, onPath: Set<String>, steps: [PathStep<Context>]) {
        if results.count >= maxPaths { return }
        results.append(StatePath(state: entry.snapshot, steps: steps))
        for edge in entry.edges where !onPath.contains(edge.nextStateKey) {
            guard let nextEntry = map[edge.nextStateKey] else { continue }
            dfs(
                nextEntry,
                onPath: onPath.union([edge.nextStateKey]),
                steps: steps + [PathStep(event: edge.event, snapshot: edge.nextSnapshot)]
            )
        }
    }

    dfs(initialEntry, onPath: [initialKey], steps: [])
    return results
}
