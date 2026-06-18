import Foundation

/// One mapped value collected from an active state node (leaf-to-root ordering).
public struct MapStateEntry<T: Sendable>: Sendable {
    public let stateNodeId: String
    public let statePath: [String]
    public let result: T

    public init(stateNodeId: String, statePath: [String], result: T) {
        self.stateNodeId = stateNodeId
        self.statePath = statePath
        self.result = result
    }
}

/// Nested mapper mirroring a machine's `states` hierarchy.
///
/// Attach a `map` closure to any node; optional `states` hold child mappers keyed
/// by state name (same keys as `StateNodeConfig.states`).
public struct StateMap<Context: Sendable, T: Sendable>: Sendable {
    public var map: (@Sendable (MachineSnapshot<Context>) -> T)?
    public var states: [String: StateMap<Context, T>]?

    public init(
        map: (@Sendable (MachineSnapshot<Context>) -> T)? = nil,
        states: [String: StateMap<Context, T>]? = nil
    ) {
        self.map = map
        self.states = states
    }

    /// Builds a mapper node with an optional nested `states` tree.
    public static func mapped(
        _ transform: @escaping @Sendable (MachineSnapshot<Context>) -> T,
        states: [String: StateMap<Context, T>] = [:]
    ) -> StateMap<Context, T> {
        StateMap(map: transform, states: states.isEmpty ? nil : states)
    }
}

func findStateMap<Context: Sendable, T: Sendable>(
    _ mapper: StateMap<Context, T>,
    path: [String]
) -> StateMap<Context, T>? {
    var current = mapper
    for key in path {
        guard let states = current.states, let child = states[key] else {
            return nil
        }
        current = child
    }
    return current
}

/// Maps a snapshot using a nested state schema, collecting every active node's `map`.
///
/// Traverses atomic leaf states and walks up each ancestor chain (parallel-safe).
/// Results are ordered leaf-to-root — most specific state first — matching XState's `mapState`.
public func mapState<Context: Sendable, T: Sendable>(
    _ snapshot: MachineSnapshot<Context>,
    mapper: StateMap<Context, T>
) -> [MapStateEntry<T>] {
    var results: [MapStateEntry<T>] = []
    var visited = Set<ObjectIdentifier>()

    let atomicNodes = snapshot._nodes.filter { $0.isAtomic() }
    for atomicNode in atomicNodes {
        var current: StateNode<Context>? = atomicNode
        while let node = current {
            let identifier = ObjectIdentifier(node)
            if visited.insert(identifier).inserted,
               let nodeMapper = findStateMap(mapper, path: node.path),
               let map = nodeMapper.map {
                results.append(
                    MapStateEntry(
                        stateNodeId: node.id,
                        statePath: node.path,
                        result: map(snapshot)
                    )
                )
            }
            current = node.parent
        }
    }

    return results
}

/// Returns the most specific mapped value, if any.
public func mapStateFirst<Context: Sendable, T: Sendable>(
    _ snapshot: MachineSnapshot<Context>,
    mapper: StateMap<Context, T>
) -> T? {
    mapState(snapshot, mapper: mapper).first?.result
}

public extension MachineSnapshot {
    func mapState<T: Sendable>(_ mapper: StateMap<Context, T>) -> [MapStateEntry<T>] {
        SwiftXState.mapState(self, mapper: mapper)
    }

    func mapStateFirst<T: Sendable>(_ mapper: StateMap<Context, T>) -> T? {
        SwiftXState.mapStateFirst(self, mapper: mapper)
    }
}