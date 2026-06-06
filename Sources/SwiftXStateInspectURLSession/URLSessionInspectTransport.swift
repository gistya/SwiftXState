#if SWIFTXSTATE_URL_SESSION_WEBSOCKET
import Foundation
import SwiftXStateInspect

/// `URLSession`-backed inspect transport. Validates endpoints against policy before connecting.
public final class URLSessionInspectTransport: InspectTransport, Sendable {
    public let policy: ConnectivityPolicy
    private let sessionFactory: @Sendable () -> URLSession

    /// Supplies a `URLSession` from the host app so connections are fully observable.
    public init(
        policy: ConnectivityPolicy,
        session: URLSession
    ) {
        self.policy = policy
        self.sessionFactory = { session }
    }

    /// Factory variant for apps that create sessions per-connection or from a pool.
    public init(
        policy: ConnectivityPolicy,
        sessionFactory: @escaping @Sendable () -> URLSession
    ) {
        self.policy = policy
        self.sessionFactory = sessionFactory
    }

    public func connect(to endpoint: InspectEndpoint) async throws -> any InspectSession {
        let validated = try EndpointValidator(policy: policy).validate(endpoint)
        guard let url = validated.url else {
            throw InspectTransportError.invalidEndpoint(validated.host)
        }

        guard validated.scheme == .ws || validated.scheme == .wss else {
            throw InspectTransportError.connectionFailed(
                "URLSessionInspectTransport supports ws/wss endpoints only"
            )
        }

        let task = sessionFactory().webSocketTask(with: url)
        task.resume()
        return URLSessionInspectSession(task: task)
    }
}

actor URLSessionInspectSession: InspectSession {
    private let task: URLSessionWebSocketTask
    private var closed = false
    private var receiveTask: Task<Void, Never>?

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    private func startReceiveLoopIfNeeded() {
        guard receiveTask == nil else { return }
        receiveTask = Task { await self.drainIncomingMessages() }
    }

    /// URLSessionWebSocketTask requires an active receive loop to keep sending.
    private func drainIncomingMessages() async {
        while !closed {
            do {
                _ = try await task.receive()
            } catch {
                if !closed {
                    closed = true
                }
                break
            }
        }
    }

    func publish(_ message: InspectWireMessage) async throws {
        guard !closed else { throw InspectTransportError.notConnected }
        startReceiveLoopIfNeeded()

        let text: String
        if message.type == "stately.event" {
            guard let raw = String(data: message.payload, encoding: .utf8) else {
                throw InspectTransportError.encodingFailed
            }
            text = raw
        } else {
            let envelope = URLSessionWireEnvelope(type: message.type, payload: message.payload)
            let encoder = JSONEncoder()
            let data = try encoder.encode(envelope)
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw InspectTransportError.encodingFailed
            }
            text = encoded
        }
        try await task.send(.string(text))
    }

    func close() async {
        closed = true
        receiveTask?.cancel()
        receiveTask = nil
        task.cancel(with: .goingAway, reason: nil)
    }
}

private struct URLSessionWireEnvelope: Codable {
    var type: String
    var payload: Data

    enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    init(type: String, payload: Data) {
        self.type = type
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        if let raw = try? container.decode(String.self, forKey: .payload) {
            payload = Data(raw.utf8)
        } else {
            payload = try container.decode(Data.self, forKey: .payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if let text = String(data: payload, encoding: .utf8) {
            try container.encode(text, forKey: .payload)
        } else {
            try container.encode(payload, forKey: .payload)
        }
    }
}

/// Convenience factory using environment-aware defaults.
public enum URLSessionInspect {
    public static func transport(
        policy: ConnectivityPolicy? = nil,
        runtime: InspectRuntimeContext = InspectRuntimeContext(),
        session: URLSession = .shared
    ) -> URLSessionInspectTransport {
        URLSessionInspectTransport(
            policy: policy ?? InspectDefaults.recommendedPolicy(for: runtime),
            session: session
        )
    }

    public static func observer(
        policy: ConnectivityPolicy? = nil,
        endpoint: InspectEndpoint? = nil,
        runtime: InspectRuntimeContext = InspectRuntimeContext(),
        enablement: InspectEnablement? = nil,
        session: URLSession = .shared,
        startImmediately: Bool = true
    ) -> @Sendable (InspectionEvent) -> Void {
        let transport = transport(policy: policy, runtime: runtime, session: session)
        let configuration = InspectClientConfiguration(
            policy: policy,
            endpoint: endpoint,
            runtime: runtime,
            enablement: enablement,
            wireFormat: .envelope
        )
        return createInspectObserver(
            transport: transport,
            configuration: configuration,
            startImmediately: startImmediately
        )
    }

    /// Stately Inspector observer — sends raw `@xstate.*` events over WebSocket.
    public static func statelyObserver<Context: Sendable>(
        machine: StateMachine<Context>,
        policy: ConnectivityPolicy? = nil,
        endpoint: InspectEndpoint? = nil,
        runtime: InspectRuntimeContext = InspectRuntimeContext(),
        enablement: InspectEnablement? = nil,
        session: URLSession = .shared,
        startImmediately: Bool = true
    ) throws -> @Sendable (InspectionEvent) -> Void {
        let transport = transport(policy: policy, runtime: runtime, session: session)
        var configuration = InspectClientConfiguration(
            policy: policy,
            endpoint: endpoint ?? InspectEndpoint(host: "127.0.0.1", port: 8080),
            runtime: runtime,
            enablement: enablement,
            wireFormat: .stately
        )
        configuration.machineDefinitions.append(try InspectMachineRegistration(machine))
        return createInspectObserver(
            transport: transport,
            configuration: configuration,
            startImmediately: startImmediately
        )
    }
}
#endif