
/// A persisted snapshot for a non-machine child actor (task, callback, etc.).
/// These children cannot be fully restored; only their last-known status is kept.
public struct PersistedOpaqueChildSnapshot: Codable, Sendable, Equatable {
    public var status: SnapshotStatus
    public var error: String?
    public var output: JSONValue?

    public init(
        status: SnapshotStatus,
        error: String? = nil,
        output: JSONValue? = nil
    ) {
        self.status = status
        self.error = error
        self.output = output
    }
}

/// A persisted child actor snapshot — either a full machine snapshot or opaque status.
public enum PersistedChildSnapshot: Sendable, Equatable {
    case machine(PersistedSnapshot)
    case opaque(PersistedOpaqueChildSnapshot)
}

extension PersistedChildSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case machine
        case opaque
    }

    private enum Kind: String, Codable {
        case machine
        case opaque
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .machine:
            self = .machine(try container.decode(PersistedSnapshot.self, forKey: .machine))
        case .opaque:
            self = .opaque(try container.decode(PersistedOpaqueChildSnapshot.self, forKey: .opaque))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .machine(snapshot):
            try container.encode(Kind.machine, forKey: .kind)
            try container.encode(snapshot, forKey: .machine)
        case let .opaque(snapshot):
            try container.encode(Kind.opaque, forKey: .kind)
            try container.encode(snapshot, forKey: .opaque)
        }
    }
}

/// A serializable machine snapshot suitable for persistence and restoration.
public struct PersistedSnapshot: Codable, Sendable, Equatable {
    public var machineId: String
    public var status: SnapshotStatus
    public var value: StateValue
    public var context: [UInt8]
    public var tags: [String]
    public var historyValue: [String: [String]]
    public var output: JSONValue?
    public var error: JSONValue?
    public var children: [String: PersistedChildSnapshot]

    public init(
        machineId: String,
        status: SnapshotStatus,
        value: StateValue,
        context: [UInt8],
        tags: [String],
        historyValue: [String: [String]] = [:],
        output: JSONValue? = nil,
        error: JSONValue? = nil,
        children: [String: PersistedChildSnapshot] = [:]
    ) {
        self.machineId = machineId
        self.status = status
        self.value = value
        self.context = context
        self.tags = tags
        self.historyValue = historyValue
        self.output = output
        self.error = error
        self.children = children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machineId = try container.decode(String.self, forKey: .machineId)
        status = try container.decode(SnapshotStatus.self, forKey: .status)
        value = try container.decode(StateValue.self, forKey: .value)
        context = try container.decode([UInt8].self, forKey: .context)
        tags = try container.decode([String].self, forKey: .tags)
        historyValue = try container.decodeIfPresent([String: [String]].self, forKey: .historyValue) ?? [:]
        output = try container.decodeIfPresent(JSONValue.self, forKey: .output)
        error = try container.decodeIfPresent(JSONValue.self, forKey: .error)
        children = try container.decodeIfPresent([String: PersistedChildSnapshot].self, forKey: .children) ?? [:]
    }

}

public enum PersistenceError: Error, Equatable {
    case actorNotStarted
    case machineMismatch(expected: String, actual: String)
    case contextEncodingFailed
    case contextDecodingFailed
    case unknownState(String)
    case childMachineMismatch(childId: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .actorNotStarted:
            return "Actor has not been started"
        case let .machineMismatch(expected, actual):
            return "Persisted snapshot is for machine '\(expected)', but actor uses '\(actual)'"
        case .contextEncodingFailed:
            return "Failed to encode actor context"
        case .contextDecodingFailed:
            return "Failed to decode persisted context"
        case let .unknownState(state):
            return "Unknown persisted state '\(state)'"
        case let .childMachineMismatch(childId, expected, actual):
            return "Persisted child '\(childId)' is for machine '\(expected)', but actor uses '\(actual)'"
        }
    }
}

/// Creates a persisted snapshot from a live machine snapshot, given the context **already encoded**
/// to bytes.
///
/// This is the primitive every other overload funnels through: it does all the snapshot work
/// (state-node resolution, history, child snapshots) without caring *how* the context was encoded, so
/// it needs neither `Codable` nor reflection and stays available under Embedded Swift. Prefer the
/// convenience overloads — `getPersistedSnapshot(from:children:)` for a ``ContextPersistable``
/// context, or the `Codable` overload in `SwiftXStateCodable`.
public func getPersistedSnapshot<Context: Sendable>(
    from snapshot: MachineSnapshot<Context>,
    contextBytes: [UInt8],
    children: [String: PersistedChildSnapshot] = [:]
) throws -> PersistedSnapshot {
    let contextData = contextBytes

    return PersistedSnapshot(
        machineId: snapshot.machine.id,
        status: snapshot.status,
        value: snapshot.value,
        context: contextData,
        tags: snapshot.tags.sorted(),
        historyValue: snapshot.historyValue.persistedEntries(),
        output: snapshot.output.map(InspectJSONEncoder.encode),
        error: snapshot.error.map(InspectJSONEncoder.encode),
        children: children
    )
}

/// Creates a persisted snapshot from a ``ContextPersistable`` context — the Embedded-safe path.
/// Projects the context to a ``JSONValue`` and serializes it with the core's dependency-free writer.
public func getPersistedSnapshot<Context: ContextPersistable & Sendable>(
    from snapshot: MachineSnapshot<Context>,
    children: [String: PersistedChildSnapshot] = [:]
) throws -> PersistedSnapshot {
    guard let json = try? snapshot.context.persistedProjection() else {
        throw PersistenceError.contextEncodingFailed
    }
    return try getPersistedSnapshot(
        from: snapshot,
        contextBytes: Array(json.serialized().utf8),
        children: children
    )
}

/// Restores a machine snapshot from persisted data, given the context **already decoded**.
///
/// The primitive every other overload funnels through — no `Codable`, no reflection, so it stays
/// available under Embedded Swift.
public func restoreSnapshot<Context: Sendable>(
    machine: ResolvedMachine<Context>,
    persisted: PersistedSnapshot,
    decodedContext context: Context
) throws -> MachineSnapshot<Context> {
    if persisted.machineId != machine.id {
        throw PersistenceError.machineMismatch(expected: persisted.machineId, actual: machine.id)
    }

    let seedNodes = getStateNodesFromValue(persisted.value, in: machine.root)
    let nodes = getAllStateNodes(StateNodeSet(seedNodes))
    let historyValue = HistoryValue<Context>(persisted: persisted.historyValue, machine: machine)

    return MachineSnapshot(
        machine: machine,
        value: persisted.value,
        context: context,
        nodes: nodes.sorted { $0.order < $1.order },
        tags: Set(persisted.tags),
        status: persisted.status,
        historyValue: historyValue,
        output: persisted.output.flatMap(decodeSendableValue),
        error: persisted.error.flatMap(decodeSendableValue),
        children: childActorSnapshots(from: persisted.children)
    )
}

/// Restores a machine snapshot for a ``ContextPersistable`` context — the Embedded-safe path.
/// Pass `context:` to override the persisted value instead of materializing it.
public func restoreSnapshot<Context: ContextPersistable & Sendable>(
    machine: ResolvedMachine<Context>,
    persisted: PersistedSnapshot,
    context overrideContext: Context? = nil
) throws -> MachineSnapshot<Context> {
    let context: Context
    if let overrideContext {
        context = overrideContext
    } else {
        guard let json = JSONValue.parse(String(decoding: persisted.context, as: UTF8.self)),
              let materialized = try? Context.materialized(from: json)
        else {
            throw PersistenceError.contextDecodingFailed
        }
        context = materialized
    }
    return try restoreSnapshot(machine: machine, persisted: persisted, decodedContext: context)
}

func childActorSnapshots(
    from children: [String: PersistedChildSnapshot]
) -> [String: ChildActorSnapshot] {
    var result: [String: ChildActorSnapshot] = [:]
    for (id, persisted) in children {
        switch persisted {
        case let .machine(snapshot):
            result[id] = ChildActorSnapshot(
                id: id,
                status: snapshot.status,
                value: snapshot.value.description
            )
        case let .opaque(snapshot):
            result[id] = ChildActorSnapshot(
                id: id,
                status: snapshot.status,
                error: snapshot.error
            )
        }
    }
    return result
}

private func decodeSendableValue(from json: JSONValue) -> SendableValue? {
    switch json {
    case let .string(value):
        return SendableValue(value)
    case let .number(value):
        if value.rounded() == value {
            return SendableValue(Int(value))
        }
        return SendableValue(value)
    case let .bool(value):
        return SendableValue(value)
    case .null:
        return nil
    default:
        return nil
    }
}

func getStateNodesFromValue<Context: Sendable>(
    _ stateValue: StateValue,
    in parent: StateNode<Context>
) -> [StateNode<Context>] {
    switch stateValue {
    case let .atomic(key):
        guard let child = parent.states[key] else {
            if parent.isAtomic() || parent.type == .final {
                return [parent]
            }
            return [parent]
        }
        return [parent, child]
    case let .compound(values):
        if values.isEmpty {
            return [parent]
        }
        var result = [parent]
        for key in values.keys.sorted() {
            guard let subValue = values[key], let child = parent.states[key] else { continue }
            result.append(contentsOf: getStateNodesFromValue(subValue, in: child))
        }
        return result
    }
}
