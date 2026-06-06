import Foundation
import SwiftXState

/// Connects `InspectionEvent` streams to an `InspectTransport`.
public final class InspectBridge: Sendable {
    private let transport: any InspectTransport
    private let configuration: InspectClientConfiguration
    private let state: InspectBridgeState

    public init(
        transport: any InspectTransport,
        configuration: InspectClientConfiguration = InspectClientConfiguration()
    ) {
        self.transport = transport
        self.configuration = configuration
        self.state = InspectBridgeState(
            transport: transport,
            endpoint: configuration.endpoint,
            wireFormat: configuration.wireFormat,
            machineDefinitions: configuration.machineDefinitions
        )
    }

    /// Returns an observer suitable for `ActorOptions.inspect` or `ActorSystem.inspect`.
    public func observe() -> @Sendable (InspectionEvent) -> Void {
        { [state, configuration] event in
            guard configuration.isEnabled else { return }
            if let filter = configuration.eventFilter, !filter(event) { return }
            Task { await state.publish(event) }
        }
    }

    /// Eagerly opens the transport session.
    public func start() {
        guard configuration.isEnabled else { return }
        Task { await state.ensureConnected() }
    }

    public func stop() async {
        await state.close()
    }
}

actor InspectBridgeState {
    private let transport: any InspectTransport
    private let endpoint: InspectEndpoint
    private let wireFormat: InspectWireFormat
    private var machineDefinitions: [String: String]
    private var wireStateValues: [String: String]
    private var statelyConverter: StatelyWireConverter
    private var session: (any InspectSession)?
    private var connectTask: Task<Void, Error>?
    private var publishTail: Task<Void, Never>?

    init(
        transport: any InspectTransport,
        endpoint: InspectEndpoint,
        wireFormat: InspectWireFormat,
        machineDefinitions: [InspectMachineRegistration]
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.wireFormat = wireFormat
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
        self.statelyConverter = StatelyWireConverter(machineDefinitions: machineDefinitions)
    }

    private func registerDefinition(machineId: String, definitionJSON: String) {
        machineDefinitions[machineId] = definitionJSON
        rebuildConverter()
    }

    private func rebuildConverter() {
        statelyConverter = StatelyWireConverter(
            machineDefinitions: machineDefinitions.map { machineId, definitionJSON in
                InspectMachineRegistration(
                    machineId: machineId,
                    definitionJSON: definitionJSON,
                    wireStateValue: wireStateValues[machineId]
                )
            }
        )
    }

    func ensureConnected() async {
        if session != nil { return }
        if let connectTask {
            _ = try? await connectTask.value
            return
        }

        let task = Task {
            let connected = try await transport.validatedConnect(to: endpoint)
            await self.attach(session: connected)
        }
        connectTask = task
        _ = try? await task.value
        connectTask = nil
    }

    private func attach(session: any InspectSession) {
        self.session = session
    }

    func publish(_ event: InspectionEvent) async {
        let previous = publishTail
        let task = Task {
            await previous?.value
            await self.publishNow(event)
        }
        publishTail = task
        await task.value
    }

    private func publishNow(_ event: InspectionEvent) async {
        if let definitionJSON = event.definitionJSON,
           let machineId = event.actor.machineId {
            registerDefinition(machineId: machineId, definitionJSON: definitionJSON)
        }

        await ensureConnected()
        guard let session else { return }

        do {
            guard let message = try makeWireMessage(for: event) else { return }
            try await session.publish(message)
        } catch {
            // Drop on encoding/transport errors — inspect must not crash the app.
        }
    }

    private func makeWireMessage(for event: InspectionEvent) throws -> InspectWireMessage? {
        switch wireFormat {
        case .envelope:
            let wire = InspectWireEvent(from: event)
            return try InspectWireMessage.inspectionEvent(wire)
        case .stately:
            guard let data = statelyConverter.wireData(for: event) else { return nil }
            return InspectWireMessage.statelyEvent(data)
        }
    }

    func close() async {
        connectTask?.cancel()
        connectTask = nil
        await publishTail?.value
        publishTail = nil
        await session?.close()
        session = nil
    }
}

/// Creates an inspect bridge and returns its observer closure.
public func createInspectObserver(
    transport: any InspectTransport,
    configuration: InspectClientConfiguration = InspectClientConfiguration(),
    startImmediately: Bool = true
) -> @Sendable (InspectionEvent) -> Void {
    let bridge = InspectBridge(transport: transport, configuration: configuration)
    if startImmediately {
        bridge.start()
    }
    return bridge.observe()
}

/// Stately Inspector observer with machine definition registration.
public func createStatelyInspectObserver<Context: Sendable>(
    transport: any InspectTransport,
    machine: StateMachine<Context>,
    configuration: InspectClientConfiguration = InspectClientConfiguration(),
    startImmediately: Bool = true
) throws -> @Sendable (InspectionEvent) -> Void {
    var resolved = configuration
    resolved.wireFormat = .stately
    resolved.machineDefinitions.append(try InspectMachineRegistration(machine))
    return createInspectObserver(
        transport: transport,
        configuration: resolved,
        startImmediately: startImmediately
    )
}