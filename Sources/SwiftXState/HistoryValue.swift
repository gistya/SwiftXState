import Foundation

/// Maps history state node IDs to the state nodes that were active when their
/// parent region was last exited.
struct HistoryValue<Context: Sendable>: Sendable {
    private var storage: [String: [StateNode<Context>]] = [:]

    init() {}

    init(copying other: HistoryValue<Context>) {
        self.storage = other.storage
    }

    func nodes(for historyNodeId: String) -> [StateNode<Context>]? {
        storage[historyNodeId]
    }

    mutating func set(_ nodes: [StateNode<Context>], for historyNodeId: String) {
        storage[historyNodeId] = nodes
    }

    func persistedEntries() -> [String: [String]] {
        storage.mapValues { $0.map(\.id) }
    }

    init(
        persisted entries: [String: [String]],
        machine: StateMachine<Context>
    ) {
        self.init()
        for (historyNodeId, nodeIds) in entries {
            let nodes = nodeIds.compactMap { machine.idMap[$0] }
            set(nodes, for: historyNodeId)
        }
    }
}