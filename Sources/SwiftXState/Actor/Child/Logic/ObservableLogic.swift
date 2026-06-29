import Foundation

/// The `fromObservable` child as an `ActorLogic` (XState's `fromObservable`). Subscribes
/// synchronously in `setUp` (returning the unsubscribe as cleanup). Each value optionally pushes a
/// `SnapshotActorEvent` (when `syncSnapshot`); completion delivers `complete(lastValue)`, an error
/// delivers `fail`. All parent deliveries ride the ordered chain via the scope.
struct ObservableLogic<Context: Sendable & Equatable>: ActorLogic {
    struct State: Sendable, Equatable {}

    let logic: ObservableActorLogic<Context>
    let syncSnapshot: Bool
    let system: ActorSystem

    func initialState(input: SendableValue?) -> State { State() }
    func step(_ snapshot: State, on event: any Eventable) -> State { snapshot }
    func status(of snapshot: State) -> SnapshotStatus { .active }

    func setUp(_ scope: ActorScope<State>) -> (@Sendable () -> Void)? {
        let observableScope = ObservableActorScope(
            input: scope.input,
            system: system,
            emit: scope.emit
        )
        let last = LastValueBox<Context>()
        let stream = logic.create(observableScope)
        let subscription = stream.subscribe(
            next: { value in
                last.set(value)
                if syncSnapshot {
                    scope.sendToParent(SnapshotActorEvent(
                        actorId: scope.actorId,
                        snapshot: ChildActorSnapshot(id: scope.actorId, status: .active, value: String(describing: value))
                    ))
                }
            },
            onError: { message in scope.fail(message) },
            onComplete: { scope.complete(last.get().map { SendableValue($0) }) }
        )
        return { subscription.cancel() }
    }
}

/// Thread-safe holder for an observable's latest value (set on the stream's thread, read at complete).
private final class LastValueBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Value? { lock.lock(); defer { lock.unlock() }; return value }
}
