import Foundation

/// The `fromCallback` child expressed as an `ActorLogic` (XState v6's `CallbackActorLogic`). It has
/// no meaningful snapshot — just a lifecycle status — and drives itself from `run`: it hands the
/// user's callback a `CallbackActorScope` built from the runtime scope's `receive`/`sendToParent`/
/// `emit`, and returns the callback's dispose as the run cleanup. Incoming events reach the user's
/// `receive` handlers via `LogicActor`'s receiver routing.
struct CallbackLogic: ActorLogic {
    struct State: Sendable, Equatable {
        var stopped = false
    }

    let callback: CallbackActorLogic
    let system: ActorSystem

    func initialState(input: SendableValue?) -> State { State() }

    // Events are consumed by the callback's `receive` handlers (LogicActor routes them); the snapshot
    // doesn't fold events.
    func step(_ snapshot: State, on event: any Eventable) -> State { snapshot }

    func status(of snapshot: State) -> SnapshotStatus { snapshot.stopped ? .stopped : .active }

    func stoppedSnapshot(_ snapshot: State) -> State { State(stopped: true) }

    func setUp(_ scope: ActorScope<State>) -> (@Sendable () -> Void)? {
        let callbackScope = CallbackActorScope(
            input: scope.input,
            sendToParent: scope.sendToParent,
            receive: scope.receive,
            emit: scope.emit,
            system: system
        )
        return callback.run(callbackScope)
    }
}

/// A `ChildActor` adapter wrapping the generic `LogicActor` — XState's "an `ActorRef` wraps the
/// interpreter". One generic adapter replaces the per-kind `*ChildRef` classes: the parent talks to
/// it through `ChildActor` while the real work runs in `LogicActor<L>`. `input` is captured here and
/// applied at `start()` (the child-lifecycle `start()` takes no args). Status is tracked across
/// `start`/`stop`, which suffices for the long-running runnable children (callback); kinds that
/// complete on their own will add snapshot observation when migrated.
final class LogicChildActor<L: ActorLogic>: ChildActor, @unchecked Sendable {
    private let actor: LogicActor<L>
    let id: String
    let systemId: String?
    private let input: SendableValue?
    private let inspectableValue: Bool

    private let lock = NSLock()
    private var cachedStatus: SnapshotStatus = .stopped

    var status: SnapshotStatus { lock.withLock { cachedStatus } }
    var inspectable: Bool { inspectableValue }
    var machineId: String? { nil }
    var definitionJSON: String? { nil }

    init(
        actor: LogicActor<L>,
        id: String,
        systemId: String?,
        input: SendableValue?,
        inspectable: Bool
    ) {
        self.actor = actor
        self.id = id
        self.systemId = systemId
        self.input = input
        self.inspectableValue = inspectable
    }

    func start() async {
        await actor.start(input: input)
        let status = await actor.status
        lock.withLock { cachedStatus = status }
    }

    func stop() async {
        await actor.stop()
        lock.withLock { cachedStatus = .stopped }
    }

    func send(_ event: any Eventable) async {
        await actor.send(event)
    }

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) async -> Subscription {
        await actor.on(eventType, handler: handler)
    }
}

extension LogicChildActor: PersistedChildSnapshotProviding {
    func makePersistedChildSnapshot() async throws -> PersistedChildSnapshot? {
        guard status != .stopped else { return nil }
        return .opaque(PersistedOpaqueChildSnapshot(status: status))
    }
}
