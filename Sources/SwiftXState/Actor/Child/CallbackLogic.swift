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

