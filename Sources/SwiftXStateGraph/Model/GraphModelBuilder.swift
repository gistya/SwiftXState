import Foundation

/// Builds a `GraphModel` by walking the live `ResolvedMachine` tree. Every node and
/// transition is read from the public `StateNode` surface — no scaffolding, no guesses.
public enum GraphModelBuilder {
    public static func build<Context: Sendable>(from machine: ResolvedMachine<Context>) -> GraphModel {
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
        return GraphModel(
            machineID: machine.id, rootID: machine.root.id, nodes: nodes, edges: edges,
            useAutoLayoutForInspection: machine.config.useAutoLayoutForInspection
        )
    }

    // MARK: Build from an exported definition (type-erased)

    /// Builds a `GraphModel` from the XState-compatible JSON that `ResolvedMachine.definitionJSON()`
    /// emits (see `MachineDefinitionExporter`). This lets an inspector graph a *type-erased* actor
    /// from its definition alone — no `ResolvedMachine<Context>` required.
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

        // Inspector auto-layout opt-out (default `true` when the key is absent — see the exporter).
        let autoLayout: Bool = { if case let .bool(b)? = root["useAutoLayoutForInspection"] { return b }; return true }()

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
                let classification: (label: String, kind: GraphEdgeKind?) = classify(eventType: event)
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
            // Invoked child actors serialize their completion transitions under `invoke[].onDone` /
            // `invoke[].onError` — NOT under `on`. Walk them so the graph shows where a state goes when
            // its invoke finishes (e.g. `loading` → `ready` on done, → `failed` on error). Mirrors the
            // typed `build(from:)` path, which classifies `xstate.done.actor.*` / `xstate.error.*` as
            // `.invoked` "done"/"error" edges. Without this, an invoking state looks like a dead end.
            if case let .array(invokes)? = node["invoke"] {
                for entry in invokes {
                    guard let inv = object(entry) else { continue }
                    for t in targets(inv["onDone"]) {
                        pending.append(.init(source: id, label: "done", kind: .invoked, target: t.target, guarded: t.guarded))
                    }
                    for t in targets(inv["onError"]) {
                        pending.append(.init(source: id, label: "error", kind: .invoked, target: t.target, guarded: t.guarded))
                    }
                }
            }
        }

        walk(root, id: machineID, relativePath: "", key: machineID, parentID: nil, parentInitial: nil)

        // Resolve transition targets to node ids (mirrors the core's relative/`#absolute` rules).
        let nodeIDs = Set(nodes.map(\.id))
        func resolve(source: String, target: String) -> String? {
            if target.isEmpty { return nil }
            if target.hasPrefix("#") {
                // Mirror the engine's `resolveTarget` for `#id`: a custom state id, then the id
                // verbatim (`#machineId.path`), then the machineId-prefixed shorthand (`#path`, which
                // the DSL resolver emits for unique-name absolute targets). Missing this last form is
                // what dropped most transition arrows once unique targets became absolute.
                let raw = String(target.dropFirst())
                if let aliased = idAlias[raw] { return aliased }
                if nodeIDs.contains(raw) { return raw }
                let prefixed = "\(machineID).\(raw)"
                return nodeIDs.contains(prefixed) ? prefixed : nil
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

        return GraphModel(machineID: machineID, rootID: machineID, nodes: nodes, edges: edges, useAutoLayoutForInspection: autoLayout)
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
