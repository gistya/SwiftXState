import Foundation

/// Identity-based set of state nodes (class instances cannot be Hashable).
struct StateNodeSet<Context: Sendable>: Sendable {
    private var storage: [ObjectIdentifier: StateNode<Context>] = [:]

    init() {}

    init(_ nodes: some Sequence<StateNode<Context>>) {
        for node in nodes {
            insert(node)
        }
    }

    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }

    func contains(_ node: StateNode<Context>) -> Bool {
        storage[ObjectIdentifier(node)] != nil
    }

    mutating func insert(_ node: StateNode<Context>) {
        storage[ObjectIdentifier(node)] = node
    }

    mutating func remove(_ node: StateNode<Context>) {
        storage.removeValue(forKey: ObjectIdentifier(node))
    }

    func sorted(by comparator: (StateNode<Context>, StateNode<Context>) -> Bool) -> [StateNode<Context>] {
        storage.values.sorted(by: comparator)
    }

    func array() -> [StateNode<Context>] {
        Array(storage.values)
    }

    func filter(_ predicate: (StateNode<Context>) -> Bool) -> [StateNode<Context>] {
        storage.values.filter(predicate)
    }
}

extension StateNodeSet: Sequence {
    func makeIterator() -> Dictionary<ObjectIdentifier, StateNode<Context>>.Values.Iterator {
        storage.values.makeIterator()
    }
}