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
            machineDefinitions: configuration.machineDefinitions,
            contextPublishing: configuration.contextPublishing
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
    public func start() async {
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
    private let contextPublishing: InspectContextPublishing
    /// Last context published per actor — the baseline Diff Mode diffs against.
    private var lastContext: [String: JSONValue] = [:]
    /// Snapshots published for an actor since its last keyframe.
    private var sinceKeyframe: [String: Int] = [:]

    init(
        transport: any InspectTransport,
        endpoint: InspectEndpoint,
        wireFormat: InspectWireFormat,
        machineDefinitions: [InspectMachineRegistration],
        contextPublishing: InspectContextPublishing = .full
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.wireFormat = wireFormat
        self.contextPublishing = contextPublishing
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
            attach(session: connected)
        }
        connectTask = task
        _ = try? await task.value
        connectTask = nil
    }

    private func attach(session: any InspectSession) {
        self.session = session
        // A new session means a consumer that has never seen this actor's context, so every
        // baseline is stale — drop them and let the next snapshot publish a keyframe.
        lastContext.removeAll()
        sinceKeyframe.removeAll()
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
            guard let message = try makeWireMessage(for: applyContextPolicy(to: event)) else { return }
            try await session.publish(message)
        } catch {
            // Drop on encoding/transport errors — inspect must not crash the app.
        }
    }

    /// Rewrites the event's published context per ``InspectContextPublishing``.
    ///
    /// Applies to every wire format. The default ``InspectContextPublishing/full`` is a no-op, so
    /// stock Stately usage is unaffected; opting into another mode is opting into a context payload
    /// `@statelyai/inspect` cannot fully reconstruct on its own.
    private func applyContextPolicy(to event: InspectionEvent) -> InspectionEvent {
        guard let snapshot = event.snapshot else { return event }
        if case .full = contextPublishing { return event }
        let sessionId = event.actor.sessionId

        switch contextPublishing {
        case .full:
            return event

        case .none:
            return event.replacingSnapshot(snapshot.publishingContext(.object([:]), delta: nil))

        case let .selected(keys):
            guard case let .object(fields) = snapshot.context else { return event }
            let filtered = fields.filter { keys.contains($0.key) }
            return event.replacingSnapshot(snapshot.publishingContext(.object(filtered), delta: nil))

        case let .diff(keyframeEvery):
            let current = snapshot.context
            let count = sinceKeyframe[sessionId, default: 0]
            let needsKeyframe = lastContext[sessionId] == nil
                || (keyframeEvery > 0 && count >= keyframeEvery)
            if needsKeyframe {
                lastContext[sessionId] = current
                sinceKeyframe[sessionId] = 0
                return event                                   // the full context IS the keyframe
            }
            let delta = ContextDelta.between(lastContext[sessionId] ?? .object([:]), current)
            lastContext[sessionId] = current
            sinceKeyframe[sessionId] = count + 1
            return event.replacingSnapshot(
                snapshot.publishingContext(.object([:]), delta: delta.jsonValue())
            )
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
        lastContext.removeAll()
        sinceKeyframe.removeAll()
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
        Task { await bridge.start() }
    }
    return bridge.observe()
}

/// Stately Inspector observer with machine definition registration.
public func createStatelyInspectObserver<Context: Sendable>(
    transport: any InspectTransport,
    machine: ResolvedMachine<Context>,
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
