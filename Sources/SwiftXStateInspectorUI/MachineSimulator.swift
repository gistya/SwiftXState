#if SWIFTXSTATE_INSPECTOR_UI
import Foundation
import SwiftXState

/// A *structural* simulator over a static XState machine definition: given the current state
/// value and an event name, it computes the next state value by following the definition's `on`
/// transitions — handling sibling/descendant/`#absolute` targets, compound initial-descent, and
/// parallel regions.
///
/// It models **control flow only**: guards are ignored (every transition is taken), and actions /
/// `assign` / context updates are not run. That's enough to "click through" a pasted machine and
/// watch the active state move, without a real interpreter.
public struct MachineSimulator: Sendable {

    // MARK: Schema

    enum NodeType: String, Sendable { case atomic, compound, parallel, final, history }

    struct Node: Sendable {
        let id: String              // full id, e.g. "traffic.red.wait"
        let key: String             // local key, e.g. "wait"
        let parentID: String?
        let type: NodeType
        let initial: String?        // initial child key
        let childKeys: [String]     // ordered child keys
        let on: [String: [String]]  // event -> raw target strings
    }

    let rootID: String
    private let nodes: [String: Node]
    private let idAlias: [String: String]   // custom `id:` -> full id

    // MARK: Parsing

    /// Parse a machine definition JSON string. Returns `nil` if it isn't a JSON object.
    public init?(definitionJSON json: String, machineID: String) {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(root) = value else { return nil }
        self.init(root: root, machineID: machineID)
    }

    init(root: [String: JSONValue], machineID: String) {
        var nodes: [String: Node] = [:]
        var idAlias: [String: String] = [:]

        func object(_ v: JSONValue?) -> [String: JSONValue]? { if case let .object(o)? = v { return o }; return nil }
        func string(_ v: JSONValue?) -> String? { if case let .string(s)? = v { return s }; return nil }

        func rawTargets(_ value: JSONValue?) -> [String] {
            guard let value else { return [] }
            switch value {
            case let .string(s): return [s]
            case let .array(items): return items.flatMap { rawTargets($0) }
            case let .object(o):
                switch o["target"] {
                case let .string(s): return [s]
                case let .array(items): return items.compactMap { if case let .string(s) = $0 { return s }; return nil }
                default: return []
                }
            default: return []
            }
        }

        /// Normalize `invoke` (object or array) into a list of invoke objects.
        func invokeList(_ value: JSONValue?) -> [[String: JSONValue]] {
            switch value {
            case let .object(o): return [o]
            case let .array(items): return items.compactMap { object($0) }
            default: return []
            }
        }

        func walk(_ node: [String: JSONValue], id: String, key: String, parentID: String?) {
            let states = object(node["states"]) ?? [:]
            let typeString = string(node["type"])
            let type: NodeType
            switch typeString {
            case "parallel": type = .parallel
            case "final": type = .final
            case "history": type = .history
            default: type = states.isEmpty ? .atomic : .compound
            }
            if let custom = string(node["id"]) { idAlias[custom] = id }

            var on: [String: [String]] = [:]
            for (event, value) in object(node["on"]) ?? [:] {
                // Only real, user-sendable events (skip xstate.* / after / done / error).
                guard !event.hasPrefix("xstate."), !event.isEmpty else { continue }
                let targets = rawTargets(value)
                if !targets.isEmpty { on[event] = targets }
            }

            // Eventless (`always`), delayed (`after`), and invoke-completion (`onDone`/`onError`)
            // transitions are surfaced as drivable *synthetic* events. We can't auto-fire `always`
            // (guards are code), so each branch becomes a labeled button instead.
            if case let .array(always)? = node["always"] {
                let withTarget = always.filter { !rawTargets($0).isEmpty }
                for entry in withTarget {
                    let targets = rawTargets(entry)
                    let label = withTarget.count > 1 ? "always → \(targets[0])" : "always"
                    on[label] = targets
                }
            }
            for (delay, value) in object(node["after"]) ?? [:] {
                let targets = rawTargets(value)
                guard !targets.isEmpty else { continue }
                let label = Int(delay) != nil ? "after \(delay)ms" : "after \(delay)"
                on[label] = targets
            }
            for invoke in invokeList(node["invoke"]) {
                if !rawTargets(invoke["onDone"]).isEmpty { on["onDone"] = rawTargets(invoke["onDone"]) }
                if !rawTargets(invoke["onError"]).isEmpty { on["onError"] = rawTargets(invoke["onError"]) }
            }

            nodes[id] = Node(
                id: id, key: key, parentID: parentID, type: type,
                initial: string(node["initial"]),
                childKeys: states.keys.sorted(),
                on: on
            )

            for childKey in states.keys.sorted() {
                guard let childNode = object(states[childKey]) else { continue }
                walk(childNode, id: "\(id).\(childKey)", key: childKey, parentID: id)
            }
        }

        walk(root, id: machineID, key: machineID, parentID: nil)
        self.rootID = machineID
        self.nodes = nodes
        self.idAlias = idAlias
    }

    // MARK: Public queries

    /// The machine's initial state value.
    public func initialValue() -> StateValue {
        descend(rootID)
    }

    /// Event names sendable from the given configuration (across active states and their
    /// ancestors), sorted. Empty if the machine is in a final/atomic state with no handlers.
    public func availableEvents(from value: StateValue) -> [String] {
        var events: Set<String> = []
        for leaf in leafIDs(of: value) {
            var cursor: String? = leaf
            while let id = cursor, let node = nodes[id] {
                events.formUnion(node.on.keys)
                cursor = node.parentID
            }
        }
        return events.sorted()
    }

    /// Apply `event` to `value`, returning the next state value — or `nil` if no active state (or
    /// ancestor) handles it. Parallel regions that each handle the event all advance.
    public func step(from value: StateValue, event: String) -> StateValue? {
        // Find the firing transitions: for each active leaf, the nearest ancestor-or-self with a
        // handler for `event`. Dedup by source so a shared ancestor fires once.
        var firings: [(source: String, target: String)] = []
        var seenSources: Set<String> = []
        for leaf in leafIDs(of: value) {
            var cursor: String? = leaf
            while let id = cursor, let node = nodes[id] {
                if let targets = node.on[event], let raw = targets.first {
                    if seenSources.insert(id).inserted,
                       let resolved = resolve(target: raw, from: id) {
                        firings.append((id, resolved))
                    }
                    break // this region's handler found
                }
                cursor = node.parentID
            }
        }
        guard !firings.isEmpty else { return nil }

        var leaves = leafIDs(of: value)
        for firing in firings {
            apply(firing.source, target: firing.target, leaves: &leaves)
        }
        return stateValue(from: leaves)
    }

    // MARK: Transition application

    /// Exit the active leaves below the least-common-ancestor of `source`/`target`, then enter
    /// `target` (descending to its initial configuration). A compound LCA has a single active
    /// child, so only the source branch is exited; sibling parallel regions are left untouched.
    private func apply(_ source: String, target: String, leaves: inout Set<String>) {
        let lca = leastCommonAncestor(source, target)
        leaves = leaves.filter { !$0.hasPrefix(lca + ".") }   // exit strict descendants of the LCA
        for leaf in descendLeaves(target) { leaves.insert(leaf) }
    }

    // MARK: Target resolution (mirrors the graph builder / core rules)

    private func resolve(target: String, from source: String) -> String? {
        if target.isEmpty { return nil }
        if target.hasPrefix("#") {
            let raw = String(target.dropFirst())
            if let aliased = idAlias[raw] { return aliased }
            return nodes[raw] != nil ? raw : nil
        }
        if target.hasPrefix(".") {
            guard let parent = nodes[source]?.parentID else { return nil }
            let rest = String(target.drop(while: { $0 == "." }))
            return rest.isEmpty ? parent : "\(parent).\(rest)"
        }
        let first = target.split(separator: ".").first.map(String.init) ?? target
        if nodes[source]?.childKeys.contains(first) == true { return "\(source).\(target)" }
        if let parent = nodes[source]?.parentID, nodes[parent]?.childKeys.contains(first) == true {
            return "\(parent).\(target)"
        }
        if let parent = nodes[source]?.parentID { return "\(parent).\(target)" }
        return "\(rootID).\(target)"
    }

    // MARK: Tree helpers

    /// Active leaf node ids for a configuration.
    private func leafIDs(of value: StateValue) -> Set<String> {
        leafIDs(value: value, under: rootID)
    }

    private func leafIDs(value: StateValue, under nodeID: String) -> Set<String> {
        switch value {
        case let .atomic(key):
            return ["\(nodeID).\(key)"]
        case let .compound(map):
            var out: Set<String> = []
            for (key, child) in map {
                out.formUnion(leafIDs(value: child, under: "\(nodeID).\(key)"))
            }
            return out
        }
    }

    /// Descend a node to its initial-configuration value (compound initial / all parallel regions).
    private func descend(_ nodeID: String) -> StateValue {
        guard let node = nodes[nodeID], !node.childKeys.isEmpty else { return .atomic("") }
        if node.type == .parallel {
            var regions: [String: StateValue] = [:]
            for key in node.childKeys { regions[key] = descend("\(nodeID).\(key)") }
            return .compound(regions)
        }
        let initialKey = node.initial ?? node.childKeys.first!
        let childID = "\(nodeID).\(initialKey)"
        let child = nodes[childID]
        if let child, !child.childKeys.isEmpty {
            return .compound([initialKey: descend(childID)])
        }
        return .atomic(initialKey)
    }

    /// Active leaf ids reached by entering `nodeID` and descending to initial/all-regions.
    private func descendLeaves(_ nodeID: String) -> Set<String> {
        guard let node = nodes[nodeID], !node.childKeys.isEmpty else { return [nodeID] }
        if node.type == .parallel {
            var out: Set<String> = []
            for key in node.childKeys { out.formUnion(descendLeaves("\(nodeID).\(key)")) }
            return out
        }
        let initialKey = node.initial ?? node.childKeys.first!
        return descendLeaves("\(nodeID).\(initialKey)")
    }

    /// Rebuild a `StateValue` from a set of active leaf ids.
    private func stateValue(from leaves: Set<String>) -> StateValue {
        func value(_ nodeID: String) -> StateValue {
            guard let node = nodes[nodeID], !node.childKeys.isEmpty else { return .atomic("") }
            let active = node.childKeys.filter { key in
                let childID = "\(nodeID).\(key)"
                return leaves.contains(childID) || leaves.contains { isDescendant($0, ofOrEqual: childID) }
            }
            if node.type == .parallel {
                var map: [String: StateValue] = [:]
                for key in active { map[key] = value("\(nodeID).\(key)") }
                return .compound(map)
            }
            guard let key = active.first else { return .atomic("") }
            let childID = "\(nodeID).\(key)"
            if leaves.contains(childID) { return .atomic(key) }
            return .compound([key: value(childID)])
        }
        return value(rootID)
    }

    private func components(_ id: String) -> [String] { id.split(separator: ".").map(String.init) }

    private func leastCommonAncestor(_ a: String, _ b: String) -> String {
        let ca = components(a), cb = components(b)
        var common: [String] = []
        for (x, y) in zip(ca, cb) where x == y { common.append(x) }
        return common.isEmpty ? rootID : common.joined(separator: ".")
    }

    private func isDescendant(_ id: String, ofOrEqual ancestor: String) -> Bool {
        id == ancestor || id.hasPrefix(ancestor + ".")
    }
}
#endif
