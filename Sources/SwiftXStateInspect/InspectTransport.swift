import Foundation
import SwiftXState

/// A single outbound inspect message on the wire.
public struct InspectWireMessage: Sendable, Equatable, Codable {
    public var type: String
    public var payload: Data

    public init(type: String, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public static func inspectionEvent(_ event: InspectWireEvent) throws -> InspectWireMessage {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return InspectWireMessage(
            type: "inspection.event",
            payload: try encoder.encode(event)
        )
    }
}

/// Codable inspection event for transports and external viewers.
public struct InspectWireEvent: Sendable, Equatable, Codable {
    public var kind: String
    public var rootId: String
    public var actor: InspectWireActorRef
    public var source: InspectWireActorRef?
    public var event: InspectWireEventDescription?
    public var snapshot: InspectWireSnapshot?
    public var actionType: String?
    public var transitions: [InspectWireTransition]?
    public var timestamp: TimeInterval

    public init(from inspectionEvent: InspectionEvent) {
        kind = inspectionEvent.kind.rawValue
        rootId = inspectionEvent.rootId
        actor = InspectWireActorRef(from: inspectionEvent.actor)
        source = inspectionEvent.source.map(InspectWireActorRef.init(from:))
        event = inspectionEvent.event.map(InspectWireEventDescription.init(from:))
        snapshot = inspectionEvent.snapshot.map(InspectWireSnapshot.init(from:))
        actionType = inspectionEvent.actionType
        transitions = inspectionEvent.transitions?.map(InspectWireTransition.init(from:))
        timestamp = inspectionEvent.timestamp
    }
}

public struct InspectWireTransition: Sendable, Equatable, Codable {
    public var sourceId: String
    public var targetIds: [String]
    public var reenter: Bool

    public init(from transition: InspectionTransitionInfo) {
        sourceId = transition.sourceId
        targetIds = transition.targetIds
        reenter = transition.reenter
    }
}

public struct InspectWireActorRef: Sendable, Equatable, Codable {
    public var sessionId: String
    public var systemId: String?
    public var machineId: String?

    public init(from ref: InspectionActorRef) {
        sessionId = ref.sessionId
        systemId = ref.systemId
        machineId = ref.machineId
    }
}

public struct InspectWireEventDescription: Sendable, Equatable, Codable {
    public var type: String
    public var payload: JSONValue?

    public init(from description: InspectionEventDescription) {
        type = description.type
        payload = description.payload
    }
}

public struct InspectWireSnapshot: Sendable, Equatable, Codable {
    public var sessionId: String
    public var systemId: String?
    public var machineId: String?
    public var status: String
    public var value: String
    public var stateValue: String
    public var tags: [String]
    public var childCount: Int

    public init(from snapshot: InspectionSnapshot) {
        sessionId = snapshot.actor.sessionId
        systemId = snapshot.actor.systemId
        machineId = snapshot.actor.machineId
        status = String(describing: snapshot.status)
        value = snapshot.value
        stateValue = snapshot.stateValue.description
        tags = snapshot.tags.sorted()
        childCount = snapshot.childCount
    }
}

/// Active inspect session — typically app → inspector (publish-only).
public protocol InspectSession: Sendable {
    func publish(_ message: InspectWireMessage) async throws
    func close() async
}

/// Injected networking boundary for inspect transports (hexagonal port).
public protocol InspectTransport: Sendable {
    var policy: ConnectivityPolicy { get }
    func connect(to endpoint: InspectEndpoint) async throws -> any InspectSession
}

extension InspectTransport {
    public func validatedConnect(to endpoint: InspectEndpoint) async throws -> any InspectSession {
        let validator = EndpointValidator(policy: policy)
        let validated = try validator.validate(endpoint)
        return try await connect(to: validated)
    }
}