import Foundation

/// Records inspect traffic for tests and host-app monitoring.
public final class MockInspectTransport: InspectTransport, Sendable {
    public let policy: ConnectivityPolicy
    private let state = MockTransportState()

    public init(policy: ConnectivityPolicy = .localhostOnly()) {
        self.policy = policy
    }

    public func connect(to endpoint: InspectEndpoint) async throws -> any InspectSession {
        let validator = EndpointValidator(policy: policy)
        let validated = try validator.validate(endpoint)

        let session = MockInspectSession()
        await state.record(session: session, endpoint: validated)
        return session
    }

    public func recordedEndpoints() async -> [InspectEndpoint] {
        await state.endpoints
    }

    public func recordedMessages() async -> [InspectWireMessage] {
        await state.allMessages()
    }

    public func reset() async {
        await state.reset()
    }
}

actor MockTransportState {
    private var sessions: [MockInspectSession] = []
    private(set) var endpoints: [InspectEndpoint] = []

    func record(session: MockInspectSession, endpoint: InspectEndpoint) {
        sessions.append(session)
        endpoints.append(endpoint)
    }

    func allMessages() async -> [InspectWireMessage] {
        var result: [InspectWireMessage] = []
        for session in sessions {
            result.append(contentsOf: await session.recordedMessages())
        }
        return result
    }

    func reset() {
        sessions.removeAll()
        endpoints.removeAll()
    }
}

public actor MockInspectSession: InspectSession {
    private var messages: [InspectWireMessage] = []
    private var closed = false

    public init() {}

    public func publish(_ message: InspectWireMessage) async throws {
        guard !closed else { throw InspectTransportError.notConnected }
        messages.append(message)
    }

    public func close() async {
        closed = true
    }

    public func recordedMessages() -> [InspectWireMessage] {
        messages
    }
}