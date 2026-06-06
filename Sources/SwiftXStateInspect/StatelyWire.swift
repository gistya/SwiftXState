import Foundation
import SwiftXState

/// Wire format understood by Stately Inspector (`@statelyai/inspect`).
public enum InspectWireFormat: String, Sendable, Equatable, Codable {
    /// Internal `{ type, payload }` envelope used by SwiftXState file/mock transports.
    case envelope
    /// Raw `@xstate.*` events expected by Stately Inspector.
    case stately
}

/// A machine definition registered for Stately graph rendering.
public struct InspectMachineRegistration: Sendable, Equatable {
    public let machineId: String
    public let definitionJSON: String
    /// When set, snapshot wire events use this atomic state value instead of the runtime value.
    public let wireStateValue: String?

    public init(
        machineId: String,
        definitionJSON: String,
        wireStateValue: String? = nil
    ) {
        self.machineId = machineId
        self.definitionJSON = definitionJSON
        self.wireStateValue = wireStateValue
    }

    public init<Context: Sendable>(_ machine: StateMachine<Context>) throws {
        machineId = machine.id
        definitionJSON = try machine.definitionJSON()
        wireStateValue = nil
    }
}

/// Action payload on `@xstate.action` wire events.
public struct StatelyWireAction: Sendable, Equatable, Codable {
    public var type: String
    public var params: JSONValue?

    public init(type: String, params: JSONValue? = nil) {
        self.type = type
        self.params = params
    }
}

/// Converts core inspection events into the Stately Inspector wire protocol.
public struct StatelyWireConverter: Sendable {
    public static let protocolVersion = "0.7.1"

    private let machineDefinitions: [String: String]
    private let wireStateValues: [String: String]

    public init(machineDefinitions: [InspectMachineRegistration] = []) {
        var map: [String: String] = [:]
        var stateValues: [String: String] = [:]
        for registration in machineDefinitions {
            map[registration.machineId] = registration.definitionJSON
            if let wireStateValue = registration.wireStateValue {
                stateValues[registration.machineId] = wireStateValue
            }
        }
        self.machineDefinitions = map
        self.wireStateValues = stateValues
    }

    public func wireData(for event: InspectionEvent) -> Data? {
        guard let payload = statelyEvent(for: event) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(payload)
    }

    public func statelyEvent(for event: InspectionEvent) -> StatelyWireEvent? {
        switch event.kind {
        case .actor:
            return actorEvent(from: event)
        case .event:
            return eventEvent(from: event)
        case .snapshot:
            return snapshotEvent(from: event)
        case .transition:
            return transitionEvent(from: event)
        case .microstep:
            return microstepEvent(from: event)
        case .action:
            return actionEvent(from: event)
        }
    }

    private func baseWireEvent(
        type: String,
        from event: InspectionEvent
    ) -> StatelyWireEvent {
        StatelyWireEvent(
            type: type,
            rootId: event.rootId,
            sessionId: event.actor.sessionId,
            createdAt: createdAtMillis(event.timestamp),
            id: nil,
            version: Self.protocolVersion,
            name: nil,
            parentId: nil,
            sourceId: nil,
            definition: nil,
            event: nil,
            snapshot: nil,
            action: nil,
            transitions: nil
        )
    }

    private func actorEvent(from event: InspectionEvent) -> StatelyWireEvent {
        let name = event.actor.machineId ?? event.actor.sessionId
        let definition = event.definitionJSON ?? event.actor.machineId.flatMap { machineDefinitions[$0] }
        let snapshot = event.snapshot.map(snapshotObject(from:)) ?? .object(["status": .string("active")])
        var wire = baseWireEvent(type: InspectionEventKind.actor.rawValue, from: event)
        wire.name = name
        wire.parentId = event.parentSessionId
        wire.definition = definition
        wire.snapshot = snapshot
        return wire
    }

    private func eventEvent(from event: InspectionEvent) -> StatelyWireEvent? {
        guard let description = event.event else { return nil }
        var wire = baseWireEvent(type: InspectionEventKind.event.rawValue, from: event)
        wire.sourceId = event.source?.sessionId
        wire.event = eventObject(from: description)
        return wire
    }

    private func snapshotEvent(from event: InspectionEvent) -> StatelyWireEvent? {
        guard let snapshot = event.snapshot else { return nil }
        var wire = baseWireEvent(type: InspectionEventKind.snapshot.rawValue, from: event)
        wire.event = event.event.map(eventObject(from:))
        wire.snapshot = snapshotObject(from: snapshot)
        return wire
    }

    private func transitionEvent(from event: InspectionEvent) -> StatelyWireEvent? {
        guard let snapshot = event.snapshot, let description = event.event else { return nil }
        var wire = baseWireEvent(type: InspectionEventKind.transition.rawValue, from: event)
        wire.event = eventObject(from: description)
        wire.snapshot = snapshotObject(from: snapshot)
        return wire
    }

    private func microstepEvent(from event: InspectionEvent) -> StatelyWireEvent? {
        guard let snapshot = event.snapshot, let description = event.event else { return nil }
        var wire = baseWireEvent(type: InspectionEventKind.microstep.rawValue, from: event)
        wire.event = eventObject(from: description)
        wire.snapshot = snapshotObject(from: snapshot)
        if !usesInspectorWireFacade(for: event) {
            wire.transitions = transitionsArray(from: event.transitions ?? [])
        }
        return wire
    }

    private func actionEvent(from event: InspectionEvent) -> StatelyWireEvent? {
        guard let actionType = event.actionType else { return nil }
        var wire = baseWireEvent(type: InspectionEventKind.action.rawValue, from: event)
        wire.action = StatelyWireAction(type: actionType, params: .null)
        return wire
    }

    private func createdAtMillis(_ timestamp: TimeInterval) -> String {
        String(Int64(timestamp * 1000))
    }

    private func eventObject(from description: InspectionEventDescription) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string(description.type),
        ]
        if let payload = description.payload {
            object["payload"] = payload
        }
        return .object(object)
    }

    private func snapshotObject(from snapshot: InspectionSnapshot) -> JSONValue {
        let wireValue = wireStateValues[snapshot.actor.machineId ?? ""]
            .map { JSONValue.string($0) }
            ?? snapshot.stateValue.toJSONValue()
        var object: [String: JSONValue] = [
            "status": .string(snapshotStatus(snapshot.status)),
            "value": wireValue,
            "context": snapshot.context,
            "children": snapshot.children,
            "historyValue": snapshot.historyValue,
            "tags": .array(snapshot.tags.sorted().map(JSONValue.string)),
        ]
        object["output"] = snapshot.output ?? .null
        object["error"] = snapshot.error ?? .null
        return .object(object)
    }

    private func usesInspectorWireFacade(for event: InspectionEvent) -> Bool {
        wireStateValues[event.actor.machineId ?? ""] != nil
    }

    private func transitionsArray(from transitions: [InspectionTransitionInfo]) -> JSONValue {
        .array(transitions.map { $0.toJSONValue() })
    }

    private func snapshotStatus(_ status: SnapshotStatus) -> String {
        switch status {
        case .active: return "active"
        case .done: return "done"
        case .error: return "error"
        case .stopped: return "stopped"
        }
    }
}

/// Codable Stately inspection event payload.
public struct StatelyWireEvent: Sendable, Equatable, Codable {
    public var type: String
    public var rootId: String
    public var sessionId: String
    public var createdAt: String
    public var id: String?
    public var version: String

    public var name: String?
    public var parentId: String?
    public var sourceId: String?
    public var definition: String?
    public var event: JSONValue?
    public var snapshot: JSONValue?
    public var action: StatelyWireAction?
    public var transitions: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case rootId
        case sessionId
        case createdAt
        case id
        case version = "_version"
        case name
        case parentId
        case sourceId
        case definition
        case event
        case snapshot
        case action
        case transitions = "_transitions"
    }
}

extension InspectWireMessage {
    public static func statelyEvent(_ data: Data) -> InspectWireMessage {
        InspectWireMessage(type: "stately.event", payload: data)
    }

    public var statelyPayload: Data? {
        guard type == "stately.event" else { return nil }
        return payload
    }
}