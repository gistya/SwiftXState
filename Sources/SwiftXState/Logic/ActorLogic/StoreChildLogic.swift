
/// The `fromStore` child as an `ActorLogic` (XState's `fromStore`). Named `StoreChildLogic` to avoid
/// the existing `StoreLogic` reducer type. Creates the store in `setUp`, routes incoming events to
/// `store.send`, bridges the store's emits to the actor's `on(_:)`, and publishes a
/// `SnapshotActorEvent` (when `syncSnapshot`) on start and after each event.
struct StoreChildLogic<Context: Sendable & Equatable, E: Eventable>: ActorLogic {
    struct State: Sendable, Equatable {}

    let logic: StoreActorLogic<Context, E>
    let syncSnapshot: Bool

    func initialState(input: SendableValue?) -> State { State() }
    func step(_ snapshot: State, on event: any Eventable) -> State { snapshot }
    func status(of snapshot: State) -> SnapshotStatus { .active }

    func setUp(_ scope: ActorScope<State>) -> (@Sendable () -> Void)? {
        let store = logic.logic.createStore(input: scope.input)
        let emitBridge = store.on("*") { emitted in scope.emit(emitted) }

        let syncSnapshot = self.syncSnapshot
        let publish: @Sendable () -> Void = {
            guard syncSnapshot else { return }
            scope.sendToParent(SnapshotActorEvent(
                actorId: scope.actorId,
                snapshot: ChildActorSnapshot(id: scope.actorId, status: .active, value: String(describing: store.context))
            ))
        }

        publish()
        scope.receive { event in
            guard let typed = event as? E else { return }
            store.send(typed)
            publish()
        }
        return {
            emitBridge.cancel()
            store.stop()
        }
    }
}
