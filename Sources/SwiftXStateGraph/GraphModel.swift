#if SWIFTXSTATE_GRAPH_UI
import Foundation
import SwiftXState

/// The kind of a state node, mirrored from the core `StateNodeType` so the
/// renderer can stay independent of the core's internal enum naming.
public enum GraphNodeType: Sendable, Equatable {
    case atomic
    case compound
    case parallel
    case final
    case history

    /// Whether this node contains child states (and is therefore drawn as a region/container).
    public var isContainer: Bool {
        self == .compound || self == .parallel
    }
}

/// A node in the rendered graph. This is a flattened, value-type projection of a
/// `StateNode` from the live machine — everything the layout engine and renderers
/// need, with no reference back into the core types.
public struct GraphNode: Identifiable, Sendable, Equatable {
    /// Globally unique id (the core node id, e.g. `"chess.game.playing"`).
    public let id: String
    /// Display label (the local state key, or the machine id for the root).
    public let label: String
    /// Dotted path relative to the machine root (e.g. `"game.playing"`).
    /// This is what `StateValue.matches(_:)` expects, so it drives highlighting.
    public let relativePath: String
    /// Parent node id, or `nil` for the root.
    public let parentID: String?
    public let type: GraphNodeType
    /// Definition order among siblings (used for stable layout).
    public let order: Int
    /// Whether this node is its parent's `initial` child.
    public let isInitialChild: Bool
    /// Optional human description supplied in the machine config.
    public let nodeDescription: String?

    public init(
        id: String,
        label: String,
        relativePath: String,
        parentID: String?,
        type: GraphNodeType,
        order: Int,
        isInitialChild: Bool,
        nodeDescription: String?
    ) {
        self.id = id
        self.label = label
        self.relativePath = relativePath
        self.parentID = parentID
        self.type = type
        self.order = order
        self.isInitialChild = isInitialChild
        self.nodeDescription = nodeDescription
    }
}

/// The semantic category of a transition, so the renderer can style each kind.
public enum GraphEdgeKind: Sendable, Equatable {
    /// A normal event-driven transition (`on: [...]`).
    case event
    /// An eventless / "always" transition.
    case always
    /// A delayed (`after:`) transition.
    case after
    /// A transition taken when a compound/parallel region completes (`onDone`).
    case onDone
    /// An invoked-actor done/error transition.
    case invoked
}

/// A directed transition between two nodes in the rendered graph.
public struct GraphEdge: Identifiable, Sendable, Equatable {
    public let id: String
    public let from: String
    public let to: String
    /// The label drawn on the edge (event type, `after 200ms`, `done`, …).
    public let label: String
    public let kind: GraphEdgeKind
    /// Whether the transition carries a guard condition (rendered with a dashed style).
    public let isGuarded: Bool
    /// Whether the source and target are the same node (rendered as a self-loop).
    public var isSelfLoop: Bool { from == to }

    public init(
        id: String,
        from: String,
        to: String,
        label: String,
        kind: GraphEdgeKind,
        isGuarded: Bool
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
        self.kind = kind
        self.isGuarded = isGuarded
    }
}

/// The full structural model of a machine: every node and every transition,
/// derived directly from the live `StateMachine`. This is the single source of
/// truth that the layout engine and both renderers consume.
public struct GraphModel: Sendable, Equatable {
    public let machineID: String
    public let rootID: String
    public let nodes: [GraphNode]
    public let edges: [GraphEdge]

    /// Fast lookup by node id.
    public let nodesByID: [String: GraphNode]
    /// Child node ids keyed by parent id, in definition order.
    public let childrenByID: [String: [String]]

    public init(machineID: String, rootID: String, nodes: [GraphNode], edges: [GraphEdge]) {
        self.machineID = machineID
        self.rootID = rootID
        self.nodes = nodes
        self.edges = edges

        var byID: [String: GraphNode] = [:]
        byID.reserveCapacity(nodes.count)
        for node in nodes { byID[node.id] = node }
        self.nodesByID = byID

        var children: [String: [String]] = [:]
        for node in nodes where node.parentID != nil {
            children[node.parentID!, default: []].append(node.id)
        }
        // Keep children in definition order for stable layout.
        for (parent, ids) in children {
            children[parent] = ids.sorted { (byID[$0]?.order ?? 0) < (byID[$1]?.order ?? 0) }
        }
        self.childrenByID = children
    }

    public func node(_ id: String) -> GraphNode? { nodesByID[id] }
    public func children(of id: String) -> [String] { childrenByID[id] ?? [] }

    /// A stable signature of the *structure* (ids, hierarchy, transitions). Used to
    /// decide whether an expensive relayout is needed — it ignores live state.
    ///
    /// Order-independent: nodes and edges are folded in *sorted* so that two models with the
    /// same topology but a different array order (e.g. rebuilt from JSON, where dictionary
    /// iteration order isn't stable) hash equal — otherwise the renderer would needlessly
    /// rebuild on every update.
    public var structureHash: Int {
        var hasher = Hasher()
        hasher.combine(machineID)
        for node in nodes.sorted(by: { $0.id < $1.id }) {
            hasher.combine(node.id)
            hasher.combine(node.parentID)
            hasher.combine(node.order)
        }
        for edge in edges.map({ "\($0.from)\u{1}\($0.to)\u{1}\($0.label)" }).sorted() {
            hasher.combine(edge)
        }
        return hasher.finalize()
    }

    public static let empty = GraphModel(machineID: "", rootID: "", nodes: [], edges: [])
}

// MARK: - Builder

/// Builds a `GraphModel` by walking the live `StateMachine` tree. Every node and
/// transition is read from the public `StateNode` surface — no scaffolding, no guesses.
public enum GraphModelBuilder {
    public static func build<Context: Sendable>(from machine: StateMachine<Context>) -> GraphModel {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        var edgeSeq = 0

        func mapType(_ type: StateNodeType) -> GraphNodeType {
            switch type {
            case .atomic: return .atomic
            case .compound: return .compound
            case .parallel: return .parallel
            case .final: return .final
            case .history: return .history
            }
        }

        func walk(_ node: StateNode<Context>, parentID: String?) {
            let relativePath = node.path.joined(separator: ".")
            let isRoot = node.parent == nil
            let label = isRoot ? machine.id : (node.key.isEmpty ? machine.id : node.key)
            let isInitial = node.parent?.initial == node.key

            nodes.append(
                GraphNode(
                    id: node.id,
                    label: label,
                    relativePath: relativePath,
                    parentID: parentID,
                    type: mapType(node.type),
                    order: node.order,
                    isInitialChild: isInitial,
                    nodeDescription: node.description
                )
            )

            // Event-driven, delayed, and lifecycle transitions all live in `transitions`,
            // keyed by event type. `always` lives separately.
            for (eventType, transitions) in node.transitions {
                let classified = classify(eventType: eventType)
                guard let kind = classified.kind else { continue } // skip noise (snapshot events)
                for transition in transitions {
                    guard let target = transition.target?.first else { continue }
                    edgeSeq += 1
                    edges.append(
                        GraphEdge(
                            id: "e\(edgeSeq)",
                            from: node.id,
                            to: target.id,
                            label: classified.label,
                            kind: kind,
                            isGuarded: transition.config.guardRef != nil
                        )
                    )
                }
            }

            for transition in node.always {
                guard let target = transition.target?.first else { continue }
                edgeSeq += 1
                edges.append(
                    GraphEdge(
                        id: "e\(edgeSeq)",
                        from: node.id,
                        to: target.id,
                        label: "",
                        kind: .always,
                        isGuarded: transition.config.guardRef != nil
                    )
                )
            }

            for child in node.states.values.sorted(by: { $0.order < $1.order }) {
                walk(child, parentID: node.id)
            }
        }

        walk(machine.root, parentID: nil)
        return GraphModel(machineID: machine.id, rootID: machine.root.id, nodes: nodes, edges: edges)
    }

    // MARK: Build from an exported definition (type-erased)

    /// Builds a `GraphModel` from the XState-compatible JSON that `StateMachine.definitionJSON()`
    /// emits (see `MachineDefinitionExporter`). This lets an inspector graph a *type-erased* actor
    /// from its definition alone — no `StateMachine<Context>` required.
    public static func build(fromDefinitionJSON json: String, machineID: String) -> GraphModel {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .empty
        }
        return build(fromDefinition: value, machineID: machineID)
    }

    /// Builds a `GraphModel` from a decoded definition object.
    public static func build(fromDefinition definition: JSONValue, machineID: String) -> GraphModel {
        guard case let .object(root) = definition else { return .empty }

        var nodes: [GraphNode] = []
        var idAlias: [String: String] = [:]        // custom `id:` -> path-derived id
        var parentOf: [String: String] = [:]
        var childKeys: [String: Set<String>] = [:]
        var order = 0

        struct PendingEdge { let source: String; let label: String; let kind: GraphEdgeKind; let target: String; let guarded: Bool }
        var pending: [PendingEdge] = []

        func object(_ v: JSONValue?) -> [String: JSONValue]? { if case let .object(o)? = v { return o }; return nil }
        func string(_ v: JSONValue?) -> String? { if case let .string(s)? = v { return s }; return nil }

        /// Pulls `(target, guarded)` pairs out of a serialized transition value (string / object / array).
        func targets(_ value: JSONValue?) -> [(target: String, guarded: Bool)] {
            guard let value else { return [] }
            switch value {
            case let .string(s): return [(s, false)]
            case let .array(items): return items.flatMap { targets($0) }
            case let .object(o):
                let guarded = o["guard"] != nil
                switch o["target"] {
                case let .string(s): return [(s, guarded)]
                case let .array(items): return items.compactMap { if case let .string(s) = $0 { return (s, guarded) }; return nil }
                default: return []
                }
            default: return []
            }
        }

        func walk(_ node: [String: JSONValue], id: String, relativePath: String, key: String, parentID: String?, parentInitial: String?) {
            order += 1
            let states = object(node["states"]) ?? [:]
            let typeString = string(node["type"])
            let type: GraphNodeType
            switch typeString {
            case "parallel": type = .parallel
            case "final": type = .final
            case "history": type = .history
            default: type = states.isEmpty ? .atomic : .compound
            }
            if let custom = string(node["id"]) { idAlias[custom] = id }

            nodes.append(GraphNode(
                id: id,
                label: parentID == nil ? machineID : key,
                relativePath: relativePath,
                parentID: parentID,
                type: type,
                order: order,
                isInitialChild: parentInitial != nil && parentInitial == key,
                nodeDescription: string(node["description"])
            ))

            let initial = string(node["initial"])
            childKeys[id] = Set(states.keys)
            for childKey in states.keys.sorted() {
                guard let childNode = object(states[childKey]) else { continue }
                let childID = "\(id).\(childKey)"
                let childRel = relativePath.isEmpty ? childKey : "\(relativePath).\(childKey)"
                parentOf[childID] = id
                walk(childNode, id: childID, relativePath: childRel, key: childKey, parentID: id, parentInitial: initial)
            }

            for (event, value) in (object(node["on"]) ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard classify(eventType: event).kind != nil else { continue }
                for t in targets(value) {
                    pending.append(.init(source: id, label: event, kind: .event, target: t.target, guarded: t.guarded))
                }
            }
            if case let .array(always)? = node["always"] {
                for entry in always {
                    for t in targets(entry) {
                        pending.append(.init(source: id, label: "", kind: .always, target: t.target, guarded: t.guarded))
                    }
                }
            }
            for (delay, value) in object(node["after"]) ?? [:] {
                let label = Int(delay) != nil ? "after \(delay)ms" : "after \(delay)"
                for t in targets(value) {
                    pending.append(.init(source: id, label: label, kind: .after, target: t.target, guarded: t.guarded))
                }
            }
            for t in targets(node["onDone"]) {
                pending.append(.init(source: id, label: "done", kind: .onDone, target: t.target, guarded: t.guarded))
            }
        }

        walk(root, id: machineID, relativePath: "", key: machineID, parentID: nil, parentInitial: nil)

        // Resolve transition targets to node ids (mirrors the core's relative/`#absolute` rules).
        let nodeIDs = Set(nodes.map(\.id))
        func resolve(source: String, target: String) -> String? {
            if target.isEmpty { return nil }
            if target.hasPrefix("#") {
                let raw = String(target.dropFirst())
                return idAlias[raw] ?? (nodeIDs.contains(raw) ? raw : nil)
            }
            if target.hasPrefix(".") {
                guard let parent = parentOf[source] else { return nil }
                let rest = String(target.drop(while: { $0 == "." }))
                return rest.isEmpty ? parent : "\(parent).\(rest)"
            }
            let first = target.split(separator: ".").first.map(String.init) ?? target
            if childKeys[source]?.contains(first) == true { return "\(source).\(target)" }
            if let parent = parentOf[source], childKeys[parent]?.contains(first) == true { return "\(parent).\(target)" }
            if let parent = parentOf[source] { return "\(parent).\(target)" }
            return "\(machineID).\(target)"
        }

        var edges: [GraphEdge] = []
        var edgeSeq = 0
        for edge in pending {
            guard let targetID = resolve(source: edge.source, target: edge.target), nodeIDs.contains(targetID) else { continue }
            edgeSeq += 1
            edges.append(GraphEdge(id: "e\(edgeSeq)", from: edge.source, to: targetID, label: edge.label, kind: edge.kind, isGuarded: edge.guarded))
        }

        return GraphModel(machineID: machineID, rootID: machineID, nodes: nodes, edges: edges)
    }

    /// Maps a raw event-type key to a display label + edge kind, or `nil` to drop it.
    private static func classify(eventType: String) -> (label: String, kind: GraphEdgeKind?) {
        if eventType.hasPrefix("xstate.after.") {
            // Format: xstate.after.<delay>.<sourceId>
            let parts = eventType.split(separator: ".")
            let delay = parts.count > 2 ? String(parts[2]) : "?"
            let label = Int(delay) != nil ? "after \(delay)ms" : "after \(delay)"
            return (label, .after)
        }
        if eventType.hasPrefix("xstate.done.state.") {
            return ("done", .onDone)
        }
        if eventType.hasPrefix("xstate.done.actor.") {
            return ("done", .invoked)
        }
        if eventType.hasPrefix("xstate.error.") {
            return ("error", .invoked)
        }
        if eventType.hasPrefix("xstate.snapshot.") {
            return ("", nil)
        }
        return (eventType, .event)
    }
}
#endif
