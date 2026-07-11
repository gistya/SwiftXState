
/// The `fromTask` child as an `ActorLogic` (XState's `fromPromise`). Status-only snapshot; the async
/// work runs in `run`, then `scope.complete(output)` / `scope.fail(error)` deliver the
/// Done/Error event on the ordered chain and set the terminal status. Cancellation (via `stop`) runs
/// the logic's `onCancel`, matching `TaskChildRef`.
struct TaskLogic<Output: Sendable & Equatable>: ActorLogic {
    struct State: Sendable, Equatable {}

    let logic: TaskActorLogic<Output>

    func initialState(input: SendableValue?) -> State { State() }
    func step(_ snapshot: State, on event: any Eventable) -> State { snapshot }
    func status(of snapshot: State) -> SnapshotStatus { .active }  // terminal status overrides

    func run(_ scope: ActorScope<State>) async -> (@Sendable () -> Void)? {
        let taskScope = TaskActorScope(
            input: scope.input,
            sendToParent: scope.sendToParent,
            emit: scope.emit
        )
        let logic = self.logic
        let cleanup = AsyncCancelCleanup(onCancel: { await logic.onCancel(taskScope) })
        do {
            let output = try await runAsyncChildLogic(
                cleanup: cleanup,
                operation: { try await logic.run(taskScope) }
            )
            guard !Task.isCancelled else { return nil }
            scope.complete(SendableValue(output))
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            scope.fail(String(describing: error))
        }
        return nil
    }
}
