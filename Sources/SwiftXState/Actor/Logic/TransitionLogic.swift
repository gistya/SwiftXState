import Foundation

/// The `fromTransition` child as an `ActorLogic` (XState's `fromTransition`) — a genuine reducer:
/// the snapshot *is* the context, and each event folds through `logic.transition`. Runs effectful
/// `handle` because the transition can `sendToParent`/`emit`. `syncSnapshot` pushes a
/// `SnapshotActorEvent` on start and after each event.
struct TransitionLogic<Context: Sendable & Equatable>: ActorLogic {
    struct State: Sendable, Equatable { var context: Context }

    let logic: TransitionActorLogic<Context>
    let syncSnapshot: Bool

    func initialState(input: SendableValue?) -> State {
        State(context: logic.resolveInitialContext(input))
    }

    func step(_ snapshot: State, on event: any Eventable) -> State { snapshot }  // overridden by handle
    func status(of snapshot: State) -> SnapshotStatus { .active }

    func started<H: MachineHost>(input: SendableValue?, host: isolated H) async -> State {
        let state = State(context: logic.resolveInitialContext(input))
        if syncSnapshot { pushSnapshot(state.context, host: host) }
        return state
    }

    func handle<H: MachineHost>(_ event: any Eventable, _ snapshot: State, host: isolated H) async -> State {
        let scope = TransitionActorScope(
            input: nil,
            system: host.actorSystem,
            sendToParent: { childEvent in host.sendToParentOrdered(childEvent) },
            emit: { emitted in host.emit(emitted) }
        )
        let next = State(context: logic.transition(snapshot.context, event, scope))
        if syncSnapshot { pushSnapshot(next.context, host: host) }
        return next
    }

    private func pushSnapshot<H: MachineHost>(_ context: Context, host: isolated H) {
        host.sendToParentOrdered(SnapshotActorEvent(
            actorId: host.sessionId,
            snapshot: ChildActorSnapshot(id: host.sessionId, status: .active, value: String(describing: context))
        ))
    }
}
