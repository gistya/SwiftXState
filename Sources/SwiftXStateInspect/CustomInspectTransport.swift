import Foundation
import SwiftXState

/// Encodes `InspectionEvent` values for custom transports (Linux WebSocket clients, gRPC, etc.).
public struct InspectWireEncoder: Sendable {
    public var wireFormat: InspectWireFormat
    private var machineDefinitions: [InspectMachineRegistration]
    private var statelyConverter: StatelyWireConverter {
        StatelyWireConverter(machineDefinitions: machineDefinitions)
    }

    public init(
        wireFormat: InspectWireFormat = .stately,
        machineDefinitions: [InspectMachineRegistration] = []
    ) {
        self.wireFormat = wireFormat
        self.machineDefinitions = machineDefinitions
    }

    public mutating func registerMachine(_ registration: InspectMachineRegistration) {
        machineDefinitions.append(registration)
    }

    public mutating func registerMachine<Context: Sendable>(_ machine: StateMachine<Context>) throws {
        try registerMachine(InspectMachineRegistration(machine))
    }

    public func encode(_ event: InspectionEvent) throws -> InspectWireMessage? {
        switch wireFormat {
        case .envelope:
            return try InspectWireMessage.inspectionEvent(InspectWireEvent(from: event))
        case .stately:
            guard let data = statelyConverter.wireData(for: event) else { return nil }
            return InspectWireMessage.statelyEvent(data)
        }
    }
}

/// Session backed by caller-supplied publish/close hooks.
public struct ClosureInspectSession: InspectSession {
    private let publishHandler: @Sendable (InspectWireMessage) async throws -> Void
    private let closeHandler: @Sendable () async -> Void

    public init(
        publish: @escaping @Sendable (InspectWireMessage) async throws -> Void,
        close: @escaping @Sendable () async -> Void = {}
    ) {
        publishHandler = publish
        closeHandler = close
    }

    public func publish(_ message: InspectWireMessage) async throws {
        try await publishHandler(message)
    }

    public func close() async {
        await closeHandler()
    }
}

/// Injected transport backed by a caller-supplied `connect` closure.
///
/// Use this on Linux (or any platform) when you bring your own WebSocket/TCP stack instead of
/// `SwiftXStateInspectURLSession`:
///
/// ```swift
/// import SwiftXState
/// import SwiftXStateInspect
///
/// let transport = ClosureInspectTransport(policy: .localhostOnly()) { endpoint in
///     let socket = try await MyWebSocket.connect(endpoint.url!)
///     return ClosureInspectSession(
///         publish: { message in
///             let text = String(data: message.payload, encoding: .utf8)!
///             try await socket.send(text: text)
///         },
///         close: { await socket.close() }
///     )
/// }
///
/// let observe = createStatelyInspectObserver(
///     transport: transport,
///     machine: myMachine,
///     configuration: InspectClientConfiguration(endpoint: InspectEndpoint(host: "127.0.0.1", port: 8080))
/// )
/// let actor = createActor(myMachine, inspect: observe).start()
/// ```
public struct ClosureInspectTransport: InspectTransport, Sendable {
    public let policy: ConnectivityPolicy
    private let connectHandler: @Sendable (InspectEndpoint) async throws -> any InspectSession

    public init(
        policy: ConnectivityPolicy = .localhostOnly(),
        connect: @escaping @Sendable (InspectEndpoint) async throws -> any InspectSession
    ) {
        self.policy = policy
        connectHandler = connect
    }

    public func connect(to endpoint: InspectEndpoint) async throws -> any InspectSession {
        try await connectHandler(endpoint)
    }
}

/// One-way session that forwards UTF-8 wire payloads to a closure (e.g. existing socket write).
public struct TextPublishInspectSession: InspectSession, Sendable {
    private let publishText: @Sendable (String) async throws -> Void
    private let closeHandler: @Sendable () async -> Void

    public init(
        publishText: @escaping @Sendable (String) async throws -> Void,
        close: @escaping @Sendable () async -> Void = {}
    ) {
        self.publishText = publishText
        closeHandler = close
    }

    public func publish(_ message: InspectWireMessage) async throws {
        let text: String
        if message.type == "stately.event" {
            guard let raw = String(data: message.payload, encoding: .utf8) else {
                throw InspectTransportError.encodingFailed
            }
            text = raw
        } else {
            let envelope: [String: String] = [
                "type": message.type,
                "payload": String(data: message.payload, encoding: .utf8) ?? "",
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw InspectTransportError.encodingFailed
            }
            text = encoded
        }
        try await publishText(text)
    }

    public func close() async {
        await closeHandler()
    }
}