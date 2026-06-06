import Foundation

// MARK: - TestModel

/// Model-based test generation over a machine, mirroring `@xstate/graph`'s `TestModel`.
///
/// Generate coverage paths (`shortestPaths` / `simplePaths`) and walk them against a system under
/// test with `test(_:onState:onEvent:)`: drive your real component in `onEvent`, assert it matches
/// the model's predicted snapshot in `onState`.
public struct TestModel<Context: Sendable>: Sendable {
    public let machine: StateMachine<Context>
    public var options: TraversalOptions<Context>

    public init(_ machine: StateMachine<Context>, options: TraversalOptions<Context> = .init()) {
        self.machine = machine
        self.options = options
    }

    /// The behavior graph: every reachable state keyed by serialized value, with its edges.
    public func adjacency() -> [String: AdjacencyEntry<Context>] {
        getAdjacencyMap(machine, options: options)
    }

    /// Shortest path to every reachable state (one each).
    public func shortestPaths() -> [StatePath<Context>] {
        getShortestPaths(machine, options: options)
    }

    /// All simple (acyclic) paths to every reachable state.
    public func simplePaths(maxPaths: Int = 10_000) -> [StatePath<Context>] {
        getSimplePaths(machine, options: options, maxPaths: maxPaths)
    }

    /// Static checks over the reachable graph (dead ends, unreachable states).
    public func validate() -> [MachineValidationIssue] {
        SwiftXState.validate(machine, options: options)
    }

    /// Walk a generated path through test hooks. `onState` fires for the initial snapshot and then
    /// after each event; `onEvent` fires just before each event is applied. Throwing from a hook
    /// aborts the walk — the natural way to surface a failed assertion.
    public func test(
        _ path: StatePath<Context>,
        onState: (MachineSnapshot<Context>) throws -> Void = { _ in },
        onEvent: (any Eventable) throws -> Void = { _ in }
    ) rethrows {
        try onState(initialTransition(machine).snapshot)
        for step in path.steps {
            try onEvent(step.event)
            try onState(step.snapshot)
        }
    }
}

// MARK: - Validation

/// A static-analysis finding from `validate(_:)`.
public struct MachineValidationIssue: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// A declared atomic/final state that never appears in any reachable configuration.
        case unreachableState
        /// A reachable, non-final state with no outgoing transitions (you can enter but not leave).
        case deadEnd
    }
    public let kind: Kind
    /// For `deadEnd`, the serialized state value; for `unreachableState`, the declared state path.
    public let stateKey: String

    public init(kind: Kind, stateKey: String) {
        self.kind = kind
        self.stateKey = stateKey
    }
}

/// Validate a machine over its reachable graph: flags dead-end states and declared states that are
/// never reachable. Built on the same faithful traversal as path generation.
public func validate<Context: Sendable>(
    _ machine: StateMachine<Context>,
    options: TraversalOptions<Context> = .init()
) -> [MachineValidationIssue] {
    let map = getAdjacencyMap(machine, options: options)
    var issues: [MachineValidationIssue] = []

    // Dead ends: reachable, still-active states with nowhere to go.
    for (key, entry) in map.sorted(by: { $0.key < $1.key }) where entry.edges.isEmpty {
        if entry.snapshot.status == .active {
            issues.append(MachineValidationIssue(kind: .deadEnd, stateKey: key))
        }
    }

    // Unreachable: declared leaf states that never appear in any reachable configuration.
    let declared = declaredLeafPaths(machine.root)
    var reached: Set<String> = []
    for entry in map.values { reached.formUnion(activeLeafPaths(entry.snapshot.value)) }
    for leaf in declared.sorted() where !reached.contains(leaf) {
        issues.append(MachineValidationIssue(kind: .unreachableState, stateKey: leaf))
    }

    return issues
}

// MARK: - Leaf-path helpers

/// Declared atomic/final leaf state paths (dot-joined, relative to the root). Excludes history.
func declaredLeafPaths<Context: Sendable>(_ root: StateNode<Context>) -> Set<String> {
    var out: Set<String> = []
    func walk(_ node: StateNode<Context>) {
        if node.states.isEmpty {
            if !node.path.isEmpty, node.type != .history {
                out.insert(node.path.joined(separator: "."))
            }
            return
        }
        for child in node.states.values { walk(child) }
    }
    walk(root)
    return out
}

/// Active leaf state paths within a `StateValue` (dot-joined), e.g. `["red.wait"]` or
/// `["bold.on", "italic.off"]` for parallel regions.
func activeLeafPaths(_ value: StateValue, prefix: String = "") -> [String] {
    switch value {
    case let .atomic(key):
        let path = prefix.isEmpty ? key : "\(prefix).\(key)"
        return [path]
    case let .compound(map):
        return map.flatMap { key, child in
            activeLeafPaths(child, prefix: prefix.isEmpty ? key : "\(prefix).\(key)")
        }
    }
}
