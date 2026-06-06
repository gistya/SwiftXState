import Foundation

// MARK: - Replayable events

/// A persisted event that can be replayed through pure or live interpreters.
public enum ReplayableEvent: Sendable, Equatable, Codable {
    case simple(type: String, payload: JSONValue? = nil)
    case system(SystemEvent)
    case done(actorId: String, outputDescription: String?)
    case error(actorId: String, message: String)
    case snapshotSync(actorId: String, value: String?)

    public init(from event: any Eventable) {
        if let system = event as? SystemEvent {
            self = .system(system)
        } else if let done = event as? DoneActorEvent {
            self = .done(
                actorId: done.actorId,
                outputDescription: done.output.map { String(describing: $0) }
            )
        } else if let error = event as? ErrorActorEvent {
            self = .error(actorId: error.actorId, message: error.error)
        } else if let snapshot = event as? SnapshotActorEvent {
            self = .snapshotSync(actorId: snapshot.actorId, value: snapshot.snapshot.value)
        } else if let payloadEvent = event as? PayloadEvent {
            self = .simple(type: payloadEvent.type, payload: payloadEvent.payload)
        } else if let replayable = event as? any ReplayPayloadRepresentable {
            self = .simple(type: event.type, payload: replayable.replayPayload)
        } else {
            self = .simple(type: event.type)
        }
    }

    public init(from description: InspectionEventDescription) {
        switch description.type {
        case SystemEvent.`init`.type:
            self = .system(.`init`)
        case SystemEvent.stop.type:
            self = .system(.stop)
        default:
            self = .simple(type: description.type, payload: description.payload)
        }
    }

    /// Reconstructs a runtime event for replay.
    public func makeEvent(decoder: ReplayEventDecoder? = nil) -> any Eventable {
        if let decoder, let decoded = decoder(self) {
            return decoded
        }
        return defaultMakeEvent()
    }

    private func defaultMakeEvent() -> any Eventable {
        switch self {
        case let .simple(type, payload):
            if let payload {
                return PayloadEvent(type, payload: payload)
            }
            return Event(type)
        case let .system(system):
            return system
        case let .done(actorId, outputDescription):
            return DoneActorEvent(
                actorId: actorId,
                output: outputDescription.map { SendableValue($0) }
            )
        case let .error(actorId, message):
            return ErrorActorEvent(actorId: actorId, error: message)
        case let .snapshotSync(actorId, value):
            return SnapshotActorEvent(
                actorId: actorId,
                snapshot: ChildActorSnapshot(id: actorId, status: .active, value: value)
            )
        }
    }

    /// User-facing events suitable for live actor replay (excludes system init).
    public var isReplayable: Bool {
        switch self {
        case .system(.`init`), .system(.stop):
            return false
        default:
            return true
        }
    }
}

// MARK: - Recorded steps

/// One root-actor transition captured during a recording session.
public struct RecordedStep: Sendable, Equatable, Codable {
    public let index: Int
    public let timestamp: TimeInterval
    public let event: ReplayableEvent
    public let snapshotBefore: InspectionSnapshot?
    public let snapshotAfter: InspectionSnapshot
    public let actionTypes: [String]

    public init(
        index: Int,
        timestamp: TimeInterval,
        event: ReplayableEvent,
        snapshotBefore: InspectionSnapshot?,
        snapshotAfter: InspectionSnapshot,
        actionTypes: [String]
    ) {
        self.index = index
        self.event = event
        self.timestamp = timestamp
        self.snapshotBefore = snapshotBefore
        self.snapshotAfter = snapshotAfter
        self.actionTypes = actionTypes
    }
}

/// A complete recording of a root actor session.
public struct ReplaySession: Sendable, Equatable, Codable {
    public let rootId: String
    public let machineId: String?
    public let steps: [RecordedStep]
    public let allInspectionEvents: [InspectionEvent]

    public init(
        rootId: String,
        machineId: String?,
        steps: [RecordedStep],
        allInspectionEvents: [InspectionEvent]
    ) {
        self.rootId = rootId
        self.machineId = machineId
        self.steps = steps
        self.allInspectionEvents = allInspectionEvents
    }

    /// Events to send when replaying on a live actor (skips `xstate.init`).
    public var replayEvents: [ReplayableEvent] {
        steps.map(\.event).filter(\.isReplayable)
    }

    public var initialSnapshot: InspectionSnapshot? {
        if let first = steps.first {
            return first.snapshotBefore ?? first.snapshotAfter
        }
        return nil
    }

    public var finalSnapshot: InspectionSnapshot? {
        steps.last?.snapshotAfter
    }
}

// MARK: - Verification

public struct ReplayVerification: Sendable, Equatable {
    public let stepIndex: Int
    public let event: ReplayableEvent
    public let expected: InspectionSnapshot
    public let actual: InspectionSnapshot
    public let matches: Bool

    public init(
        stepIndex: Int,
        event: ReplayableEvent,
        expected: InspectionSnapshot,
        actual: InspectionSnapshot,
        matches: Bool
    ) {
        self.stepIndex = stepIndex
        self.event = event
        self.expected = expected
        self.actual = actual
        self.matches = matches
    }
}

// MARK: - Inspection recorder

/// Records inspection events into a structured `ReplaySession` for time travel and replay.
public final class InspectionRecorder: @unchecked Sendable {
    private var allEvents: [InspectionEvent] = []
    private var steps: [RecordedStep] = []
    private var rootId: String?
    private var machineId: String?
    private var lastSnapshot: InspectionSnapshot?
    private var pendingEvent: ReplayableEvent?
    private var pendingActions: [String] = []
    private let lock = NSLock()

    public init() {}

    /// Returns an inspection observer suitable for `ActorOptions.inspect` or `ActorSystem.inspect`.
    public func observe() -> @Sendable (InspectionEvent) -> Void {
        { [weak self] event in
            self?.handle(event)
        }
    }

    public func session() -> ReplaySession? {
        lock.lock()
        defer { lock.unlock() }
        guard let rootId else { return nil }
        return ReplaySession(
            rootId: rootId,
            machineId: machineId,
            steps: steps,
            allInspectionEvents: allEvents
        )
    }

    public func recordedSteps() -> [RecordedStep] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }

    public func recordedInspectionEvents() -> [InspectionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return allEvents
    }

    public func reset() {
        lock.lock()
        allEvents.removeAll()
        steps.removeAll()
        rootId = nil
        machineId = nil
        lastSnapshot = nil
        pendingEvent = nil
        pendingActions.removeAll()
        lock.unlock()
    }

    private func handle(_ event: InspectionEvent) {
        lock.lock()
        defer { lock.unlock() }

        allEvents.append(event)

        if rootId == nil {
            rootId = event.rootId
        }

        guard event.actor.sessionId == event.rootId else { return }

        if machineId == nil {
            machineId = event.actor.machineId
        }

        switch event.kind {
        case .event:
            if let description = event.event {
                pendingEvent = ReplayableEvent(from: description)
            }
        case .action:
            if let actionType = event.actionType {
                pendingActions.append(actionType)
            }
        case .transition:
            guard let after = event.snapshot else { return }
            let replayEvent = pendingEvent
                ?? event.event.map(ReplayableEvent.init(from:))
                ?? .system(.`init`)
            let step = RecordedStep(
                index: steps.count,
                timestamp: event.timestamp,
                event: replayEvent,
                snapshotBefore: lastSnapshot,
                snapshotAfter: after,
                actionTypes: pendingActions
            )
            steps.append(step)
            lastSnapshot = after
            pendingEvent = nil
            pendingActions.removeAll()
        case .snapshot:
            if let snapshot = event.snapshot {
                lastSnapshot = snapshot
            }
        case .actor, .microstep:
            break
        }
    }
}

// MARK: - Pure replay (time travel)

/// Replays events through pure `transition()` without side effects.
public func replayTransitions<Context: Sendable>(
    _ machine: StateMachine<Context>,
    context: Context,
    events: [ReplayableEvent],
    decodeEvent: ReplayEventDecoder? = nil
) -> [MachineSnapshot<Context>] {
    var (snapshot, _) = initialTransition(machine, context: context)
    var results = [snapshot]

    for replayEvent in events where replayEvent.isReplayable {
        let runtimeEvent = replayEvent.makeEvent(decoder: decodeEvent)
        let (next, _) = transition(machine, snapshot: snapshot, event: runtimeEvent)
        snapshot = next
        results.append(snapshot)
    }

    return results
}

/// Time-travels to a specific step index using pure transitions (no actor required).
public func timeTravel<Context: Sendable>(
    _ machine: StateMachine<Context>,
    context: Context,
    session: ReplaySession,
    toStep step: Int,
    decodeEvent: ReplayEventDecoder? = nil
) -> MachineSnapshot<Context>? {
    guard step >= 0, step < session.steps.count else { return nil }
    let events = session.steps.prefix(step + 1).map(\.event)
    return replayTransitions(
        machine,
        context: context,
        events: Array(events),
        decodeEvent: decodeEvent
    ).last
}

/// Verifies that pure replay matches a recorded session.
public func verifyReplay<Context: Sendable>(
    _ machine: StateMachine<Context>,
    context: Context,
    session: ReplaySession,
    decodeEvent: ReplayEventDecoder? = nil
) -> [ReplayVerification] {
    var verifications: [ReplayVerification] = []
    var (snapshot, _) = initialTransition(machine, context: context)
    var lastInspection = inspectionSnapshot(from: snapshot, rootId: session.rootId, machineId: session.machineId)

    for step in session.steps {
        if step.event.isReplayable {
            let runtimeEvent = step.event.makeEvent(decoder: decodeEvent)
            let (next, _) = transition(machine, snapshot: snapshot, event: runtimeEvent)
            snapshot = next
            lastInspection = inspectionSnapshot(from: snapshot, rootId: session.rootId, machineId: session.machineId)
        }

        let actual = step.event.isReplayable ? lastInspection : (step.snapshotBefore ?? step.snapshotAfter)
        let matches = snapshotsMatch(step.snapshotAfter, actual)
        verifications.append(
            ReplayVerification(
                stepIndex: step.index,
                event: step.event,
                expected: step.snapshotAfter,
                actual: actual,
                matches: matches
            )
        )
    }

    return verifications
}

private func inspectionSnapshot<Context>(
    from snapshot: MachineSnapshot<Context>,
    rootId: String,
    machineId: String?
) -> InspectionSnapshot {
    .from(
        snapshot,
        actor: InspectionActorRef(sessionId: rootId, machineId: machineId)
    )
}

private func snapshotsMatch(_ expected: InspectionSnapshot, _ actual: InspectionSnapshot) -> Bool {
    expected.value == actual.value
        && expected.status == actual.status
        && expected.tags == actual.tags
}

// MARK: - Live actor replay

/// Starts a fresh actor and replays a recorded session, returning per-step verification.
@discardableResult
public func replayActor<Context: Sendable>(
    _ machine: StateMachine<Context>,
    context: Context,
    session: ReplaySession,
    options: ActorOptions = ActorOptions(),
    decodeEvent: ReplayEventDecoder? = nil
) -> (actor: Actor<Context>, verifications: [ReplayVerification]) {
    let actor = createActor(machine, options: options).start(context: context)
    var verifications: [ReplayVerification] = []

    for step in session.steps where step.event.isReplayable {
        actor.send(step.event.makeEvent(decoder: decodeEvent))
        let actual = InspectionSnapshot.from(
            actor.snapshot,
            actor: InspectionActorRef(sessionId: actor.id, machineId: machine.id)
        )
        verifications.append(
            ReplayVerification(
                stepIndex: step.index,
                event: step.event,
                expected: step.snapshotAfter,
                actual: actual,
                matches: snapshotsMatch(step.snapshotAfter, actual)
            )
        )
    }

    return (actor, verifications)
}

// MARK: - Store recording

/// One store transition captured during recording.
public struct StoreRecordedStep<Context: Sendable & Equatable>: Sendable, Equatable {
    public let index: Int
    public let eventType: String
    public let snapshotBefore: StoreSnapshot<Context>
    public let snapshotAfter: StoreSnapshot<Context>

    public init(
        index: Int,
        eventType: String,
        snapshotBefore: StoreSnapshot<Context>,
        snapshotAfter: StoreSnapshot<Context>
    ) {
        self.index = index
        self.eventType = eventType
        self.snapshotBefore = snapshotBefore
        self.snapshotAfter = snapshotAfter
    }
}

/// A recorded store session.
public struct StoreReplaySession<Context: Sendable & Equatable>: Sendable, Equatable {
    public let initial: StoreSnapshot<Context>
    public let steps: [StoreRecordedStep<Context>]

    public init(initial: StoreSnapshot<Context>, steps: [StoreRecordedStep<Context>]) {
        self.initial = initial
        self.steps = steps
    }

    public var eventTypes: [String] {
        steps.map(\.eventType)
    }
}

/// Records store transitions for replay and verification.
public final class StoreRecorder<Context: Sendable & Equatable, E: Eventable>: @unchecked Sendable {
    private var steps: [StoreRecordedStep<Context>] = []
    private var initial: StoreSnapshot<Context>?
    private let lock = NSLock()

    public init() {}

    /// Sends an event through the store while recording before/after snapshots.
    public func send(_ store: Store<Context, E>, event: E) {
        lock.lock()
        if initial == nil {
            initial = store.snapshot
        }
        let before = store.snapshot
        lock.unlock()

        store.send(event)

        lock.lock()
        steps.append(
            StoreRecordedStep(
                index: steps.count,
                eventType: event.type,
                snapshotBefore: before,
                snapshotAfter: store.snapshot
            )
        )
        lock.unlock()
    }

    public func session() -> StoreReplaySession<Context>? {
        lock.lock()
        defer { lock.unlock() }
        guard let initial else { return nil }
        return StoreReplaySession(initial: initial, steps: steps)
    }

    public func reset() {
        lock.lock()
        steps.removeAll()
        initial = nil
        lock.unlock()
    }
}

/// Replays recorded store events on a fresh store.
public func replayStore<Context: Sendable & Equatable, E: Eventable>(
    _ config: StoreConfig<Context, E>,
    session: StoreReplaySession<Context>,
    events: [E]
) -> (store: Store<Context, E>, matches: Bool) {
    let store = Store(config)
    var matches = store.snapshot == session.initial

    for (index, event) in events.enumerated() {
        store.send(event)
        if index < session.steps.count {
            matches = matches && store.snapshot == session.steps[index].snapshotAfter
        }
    }

    return (store, matches)
}

/// Pure store replay using `store.transition`.
public func replayStoreTransitions<Context: Sendable & Equatable, E: Eventable>(
    _ store: Store<Context, E>,
    from initial: StoreSnapshot<Context>,
    events: [E]
) -> [StoreSnapshot<Context>] {
    var snapshot = initial
    var results = [snapshot]
    for event in events {
        snapshot = store.transition(snapshot, event: event)
        results.append(snapshot)
    }
    return results
}