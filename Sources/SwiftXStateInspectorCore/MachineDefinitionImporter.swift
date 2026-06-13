import Foundation
import SwiftXState

/// Parses a pasted XState-format machine *definition* (the JSON that
/// `StateMachine.definitionJSON()` emits, or an equivalent XState config) into an
/// `InspectionEvent` the inspector can ingest — without needing a typed, running machine.
///
/// What we can reconstruct from a static definition:
/// - the **graph** (structure), via `GraphModelBuilder.build(fromDefinitionJSON:)`,
/// - the **initial state value** (descending `initial`/`states`, expanding `parallel` regions),
/// - the **initial context** (the top-level `context` object, if present).
///
/// We can't *run* the machine (guards/actions are code, not data), so there's no live event
/// feed — but the Graph and State tabs light up immediately from the paste.
public enum MachineDefinitionImporter {

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case empty
        case invalidJSON(String)
        case notAnObject

        public var description: String {
            switch self {
            case .empty: return "Paste an XState machine definition (JSON) to load it."
            case let .invalidJSON(detail): return "Couldn't parse JSON: \(detail)"
            case .notAnObject: return "Expected a JSON object describing a machine (with \"states\")."
            }
        }
    }

    /// Build a synthetic `.actor` registration event (carrying the definition + an initial
    /// snapshot) from a pasted definition string.
    ///
    /// - Parameters:
    ///   - json: the raw pasted definition string.
    ///   - fallbackID: id to use when the definition has no top-level `id`.
    public static func makeEvent(
        fromJSON json: String,
        fallbackID: String = "pasted-machine"
    ) throws -> InspectionEvent {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.empty }

        guard let data = trimmed.data(using: .utf8) else {
            throw ImportError.invalidJSON("not valid UTF-8")
        }
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ImportError.invalidJSON(error.localizedDescription)
        }
        guard case let .object(obj) = root else { throw ImportError.notAnObject }

        let machineID = string(obj["id"]) ?? fallbackID
        let initial = resolveInitial(obj)
        let context = obj["context"] ?? .object([:])

        let ref = InspectionActorRef(sessionId: machineID, systemId: machineID, machineId: machineID)
        let snapshot = InspectionSnapshot(
            actor: ref,
            status: .active,
            value: initial.description,
            stateValue: initial,
            tags: [],
            childCount: 0,
            context: context
        )
        return InspectionEvent(
            kind: .actor,
            rootId: machineID,
            actor: ref,
            snapshot: snapshot,
            definitionJSON: trimmed
        )
    }

    // MARK: - Initial-state resolution

    /// The active state value *inside* a state node, descending `initial` (compound) or
    /// expanding every region (parallel). Mirrors XState's initial-configuration rules.
    static func resolveInitial(_ node: [String: JSONValue]) -> StateValue {
        let children = object(node["children"]) ?? object(node["states"]) ?? [:]

        // Parallel: every region is active simultaneously.
        if string(node["type"]) == "parallel" {
            var regions: [String: StateValue] = [:]
            for (key, child) in children {
                regions[key] = resolveInitial(object(child) ?? [:])
            }
            return .compound(regions)
        }

        // Compound: descend into the initial child (or, lacking one, the first child).
        guard !children.isEmpty else { return .atomic("") } // leaf — caller supplies the key
        let initialKey = string(node["initial"]) ?? children.keys.sorted().first!
        let childNode = object(children[initialKey]) ?? [:]
        let grandchildren = object(childNode["children"]) ?? object(childNode["states"]) ?? [:]
        let childIsParallel = string(childNode["type"]) == "parallel"

        if grandchildren.isEmpty && !childIsParallel {
            return .atomic(initialKey)                 // initial child is a leaf
        }
        return .compound([initialKey: resolveInitial(childNode)])
    }

    // MARK: - JSONValue accessors

    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        if case let .object(obj)? = value { return obj }
        return nil
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case let .string(s)? = value { return s }
        return nil
    }
}
