import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Wall-clock nanoseconds since the Unix epoch. `TimeInterval` (a `Double`) can't hold true
/// nanosecond resolution near the current epoch (~200ns ULP), so inspection stamps this integer
/// clock in addition to the `Double` `timestamp` for nanosecond-precise ordering/display.
@inlinable
public func wallClockNanosecondsSince1970() -> UInt64 {
    #if canImport(Darwin) || canImport(Glibc)
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    #elseif canImport(WASILibc)
    // wasi-libc defines CLOCK_REALTIME as `(&_CLOCK_REALTIME)` over an incomplete
    // struct, so neither the macro nor the symbol imports into Swift (clockid_t
    // lands as OpaquePointer). Call the underlying WASI syscall directly instead;
    // this keeps the module free of Foundation.
    var nanos: __wasi_timestamp_t = 0
    _ = __wasi_clock_time_get(__wasi_clockid_t(0), 1_000, &nanos)  // 0 == REALTIME
    return UInt64(nanos)
    #else
    return 0
    #endif
}

/// Inspection event kinds, aligned with XState's `@xstate.*` protocol.
public enum InspectionEventKind: String, Sendable, Equatable {
    case actor = "@xstate.actor"
    case event = "@xstate.event"
    case snapshot = "@xstate.snapshot"
    case transition = "@xstate.transition"
    case microstep = "@xstate.microstep"
    case action = "@xstate.action"
}

/// A stable reference to an actor within an inspection stream.
public struct InspectionActorRef: Sendable, Equatable, Hashable {
    public let sessionId: String
    public let systemId: String?
    public let machineId: String?

    public init(sessionId: String, systemId: String? = nil, machineId: String? = nil) {
        self.sessionId = sessionId
        self.systemId = systemId
        self.machineId = machineId
    }

    public static func from(_ ref: any ActorSystemRef, machineId: String? = nil) -> InspectionActorRef {
        InspectionActorRef(
            sessionId: ref.sessionId,
            systemId: ref.systemId,
            machineId: machineId
        )
    }
}

/// Serializable event description for inspection transports.
public struct InspectionEventDescription: Sendable, Equatable {
    public let type: String
    public let payload: JSONValue?

    public init(type: String, payload: JSONValue? = nil) {
        self.type = type
        self.payload = payload
    }

    public init(type: String, payloadString: String?) {
        self.type = type
        self.payload = payloadString.map(JSONValue.string)
    }

    public static func describe(_ event: any Eventable) -> InspectionEventDescription {
        if let done = event as? DoneStateEvent {
            return InspectionEventDescription(
                type: done.type,
                payloadString: done.output.map { describeValue($0) }
            )
        }
        if let done = event as? DoneActorEvent {
            return InspectionEventDescription(
                type: done.type,
                payloadString: done.output.map { describeValue($0) }
            )
        }
        if let error = event as? ErrorActorEvent {
            return InspectionEventDescription(type: error.type, payloadString: error.error)
        }
        if let snapshot = event as? SnapshotActorEvent {
            return InspectionEventDescription(
                type: snapshot.type,
                payloadString: snapshot.snapshot.value
            )
        }
        if let payloadEvent = event as? PayloadEvent {
            return InspectionEventDescription(type: payloadEvent.type, payload: payloadEvent.payload)
        }
        if let replayable = event as? any ReplayPayloadRepresentable {
            return InspectionEventDescription(type: event.type, payload: replayable.replayPayload)
        }
        return InspectionEventDescription(type: event.type)
    }
}

/// Serializable transition metadata for microstep inspection.
public struct InspectionTransitionInfo: Sendable, Equatable {
    public let sourceId: String
    public let targetIds: [String]
    public let reenter: Bool

    public init(sourceId: String, targetIds: [String], reenter: Bool) {
        self.sourceId = sourceId
        self.targetIds = targetIds
        self.reenter = reenter
    }

    static func from<Context: Sendable>(_ transitions: [ResolvedTransition<Context>]) -> [InspectionTransitionInfo] {
        transitions.map { transition in
            InspectionTransitionInfo(
                sourceId: transition.source.id,
                targetIds: transition.target?.map(\.id) ?? [],
                reenter: transition.reenter
            )
        }
    }

    public func toJSONValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "source": .string(sourceId),
            "reenter": .bool(reenter),
        ]
        if !targetIds.isEmpty {
            object["target"] = .array(targetIds.map(JSONValue.string))
        }
        return .object(object)
    }
}

/// Serializable snapshot description for inspection transports.
public struct InspectionSnapshot: Sendable, Equatable {
    public let actor: InspectionActorRef
    public let status: SnapshotStatus
    public let value: String
    public let stateValue: StateValue
    public let tags: Set<String>
    public let childCount: Int
    public let context: JSONValue
    public let children: JSONValue
    public let historyValue: JSONValue
    public let output: JSONValue?
    public let error: JSONValue?

    /// Set when the transport publishes in **Diff Mode**: the change to ``context`` since this
    /// actor's last published snapshot, in ``ContextDelta``'s wire form. When this is non-`nil`,
    /// ``context`` is empty and the consumer reconstructs by applying the delta to what it already
    /// holds. `nil` means ``context`` is the full value (the default).
    public let contextDelta: JSONValue?

    public init(
        actor: InspectionActorRef,
        status: SnapshotStatus,
        value: String,
        stateValue: StateValue,
        tags: Set<String>,
        childCount: Int,
        context: JSONValue = .object([:]),
        children: JSONValue = .object([:]),
        historyValue: JSONValue = .object([:]),
        output: JSONValue? = nil,
        error: JSONValue? = nil,
        contextDelta: JSONValue? = nil
    ) {
        self.actor = actor
        self.status = status
        self.value = value
        self.stateValue = stateValue
        self.tags = tags
        self.childCount = childCount
        self.context = context
        self.children = children
        self.historyValue = historyValue
        self.output = output
        self.error = error
        self.contextDelta = contextDelta
    }

    /// Returns a copy publishing `context` (typically empty) plus `delta` instead of the full context
    /// — how a transport switches this snapshot into Diff Mode.
    public func publishingContext(_ context: JSONValue, delta: JSONValue?) -> InspectionSnapshot {
        InspectionSnapshot(
            actor: actor,
            status: status,
            value: value,
            stateValue: stateValue,
            tags: tags,
            childCount: childCount,
            context: context,
            children: children,
            historyValue: historyValue,
            output: output,
            error: error,
            contextDelta: delta
        )
    }

    public static func from<Context>(
        _ snapshot: MachineSnapshot<Context>,
        actor: InspectionActorRef
    ) -> InspectionSnapshot {
        InspectionSnapshot(
            actor: actor,
            status: snapshot.status,
            value: snapshot.value.description,
            stateValue: snapshot.value,
            tags: snapshot.tags,
            childCount: snapshot.children.count,
            context: InspectJSONEncoder.encode(snapshot.context),
            children: InspectJSONEncoder.encodeChildren(snapshot.children),
            historyValue: .object([:]),
            output: snapshot.output.map(InspectJSONEncoder.encode),
            error: snapshot.error.map(InspectJSONEncoder.encode)
        )
    }
}

/// A single inspection event emitted by the runtime.
public struct InspectionEvent: Sendable, Equatable {
    public let kind: InspectionEventKind
    public let rootId: String
    public let actor: InspectionActorRef
    public let source: InspectionActorRef?
    public let event: InspectionEventDescription?
    public let snapshot: InspectionSnapshot?
    public let actionType: String?
    public let transitions: [InspectionTransitionInfo]?
    public let parentSessionId: String?
    public let definitionJSON: String?
    public let timestamp: Double
    /// Wall-clock nanoseconds since the Unix epoch — full-precision counterpart of `timestamp` (which,
    /// being a `Double`, loses sub-microsecond resolution). Use for nanosecond-precise display/ordering.
    public let timestampNanos: UInt64

    /// Returns a copy carrying `snapshot` instead of this event's — how a transport rewrites the
    /// published context (Diff Mode, redaction) without disturbing timing or identity.
    public func replacingSnapshot(_ snapshot: InspectionSnapshot?) -> InspectionEvent {
        InspectionEvent(
            kind: kind,
            rootId: rootId,
            actor: actor,
            source: source,
            event: event,
            snapshot: snapshot,
            actionType: actionType,
            transitions: transitions,
            parentSessionId: parentSessionId,
            definitionJSON: definitionJSON,
            timestampNanos: timestampNanos
        )
    }

    public init(
        kind: InspectionEventKind,
        rootId: String,
        actor: InspectionActorRef,
        source: InspectionActorRef? = nil,
        event: InspectionEventDescription? = nil,
        snapshot: InspectionSnapshot? = nil,
        actionType: String? = nil,
        transitions: [InspectionTransitionInfo]? = nil,
        parentSessionId: String? = nil,
        definitionJSON: String? = nil,
        timestampNanos: UInt64 = wallClockNanosecondsSince1970()
    ) {
        self.kind = kind
        self.rootId = rootId
        self.actor = actor
        self.source = source
        self.event = event
        self.snapshot = snapshot
        self.actionType = actionType
        self.transitions = transitions
        self.parentSessionId = parentSessionId
        self.definitionJSON = definitionJSON
        self.timestampNanos = timestampNanos
        self.timestamp = Double(timestampNanos) / 1_000_000_000
    }
}

// MARK: - Factories

extension InspectionEvent {
    public static func actor(
        rootId: String,
        actor: InspectionActorRef,
        parentSessionId: String? = nil,
        registrationSnapshot: InspectionSnapshot? = nil,
        definitionJSON: String? = nil
    ) -> InspectionEvent {
        InspectionEvent(
            kind: .actor,
            rootId: rootId,
            actor: actor,
            snapshot: registrationSnapshot,
            parentSessionId: parentSessionId,
            definitionJSON: definitionJSON
        )
    }

    public static func event(
        rootId: String,
        actor: InspectionActorRef,
        source: InspectionActorRef?,
        event: any Eventable
    ) -> InspectionEvent {
        InspectionEvent(
            kind: .event,
            rootId: rootId,
            actor: actor,
            source: source,
            event: .describe(event)
        )
    }

    public static func snapshot<Context>(
        rootId: String,
        actor: InspectionActorRef,
        triggeringEvent: any Eventable,
        machineSnapshot: MachineSnapshot<Context>
    ) -> InspectionEvent {
        InspectionEvent(
            kind: .snapshot,
            rootId: rootId,
            actor: actor,
            event: .describe(triggeringEvent),
            snapshot: .from(machineSnapshot, actor: actor)
        )
    }

    public static func transition<Context>(
        rootId: String,
        actor: InspectionActorRef,
        triggeringEvent: any Eventable,
        machineSnapshot: MachineSnapshot<Context>
    ) -> InspectionEvent {
        InspectionEvent(
            kind: .transition,
            rootId: rootId,
            actor: actor,
            event: .describe(triggeringEvent),
            snapshot: .from(machineSnapshot, actor: actor)
        )
    }

    public static func action(
        rootId: String,
        actor: InspectionActorRef,
        actionType: String,
        triggeringEvent: any Eventable
    ) -> InspectionEvent {
        InspectionEvent(
            kind: .action,
            rootId: rootId,
            actor: actor,
            event: .describe(triggeringEvent),
            actionType: actionType
        )
    }

    public static func microstep<Context>(
        rootId: String,
        actor: InspectionActorRef,
        triggeringEvent: InspectionEventDescription,
        machineSnapshot: MachineSnapshot<Context>,
        transitions: [ResolvedTransition<Context>]
    ) -> InspectionEvent {
        InspectionEvent(
            kind: .microstep,
            rootId: rootId,
            actor: actor,
            event: triggeringEvent,
            snapshot: .from(machineSnapshot, actor: actor),
            transitions: InspectionTransitionInfo.from(transitions)
        )
    }
}

// MARK: - Console inspector

/// Prints inspection events to stdout. Suitable for debug builds and CLI tools.
public struct ConsoleInspector: Sendable {
    public var filter: (@Sendable (InspectionEvent) -> Bool)?
    public var prefix: String

    public init(
        filter: (@Sendable (InspectionEvent) -> Bool)? = nil,
        prefix: String = "[SwiftXState]"
    ) {
        self.filter = filter
        self.prefix = prefix
    }

    public func observe() -> @Sendable (InspectionEvent) -> Void {
        { event in
            guard filter?(event) ?? true else { return }
            print("\(prefix) \(event.consoleLine)")
        }
    }
}

extension InspectionEvent {
    public var consoleLine: String {
        var parts = ["\(kind.rawValue)", "root=\(rootId)", "actor=\(actor.sessionId)"]
        if let systemId = actor.systemId {
            parts.append("systemId=\(systemId)")
        }
        if let machineId = actor.machineId {
            parts.append("machine=\(machineId)")
        }
        if let source {
            parts.append("source=\(source.sessionId)")
        }
        if let event {
            parts.append("event=\(event.type)")
        }
        if let snapshot {
            parts.append("state=\(snapshot.value)")
            parts.append("status=\(snapshot.status)")
        }
        if let actionType {
            parts.append("action=\(actionType)")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - In-memory collector

/// Collects raw inspection events. For structured recording and replay, use `InspectionRecorder`.
public final class InspectionCollector: @unchecked Sendable {
    private var events: [InspectionEvent] = []
    private let lock = Mutex(false)

    public init() {}

    public func observe() -> @Sendable (InspectionEvent) -> Void {
        { [weak self] event in
            self?.lock.lock()
            self?.events.append(event)
            self?.lock.unlock()
        }
    }

    public func recordedEvents() -> [InspectionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    public func reset() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
}

// Codable is declared out-of-line and guarded — see CodableConformances.swift for the policy.
#if !hasFeature(Embedded)
extension InspectionActorRef: Codable {}
extension InspectionEventDescription: Codable {}
extension InspectionTransitionInfo: Codable {}
extension InspectionSnapshot: Codable {}
extension InspectionEvent: Codable {}
#endif
