#if hasFeature(Embedded)
// Embedded Swift does not implicitly import the concurrency module the way full Swift does.
import _Concurrency
#endif


/// The `fromTaskGroup` child as an `ActorLogic` — structurally identical to `TaskLogic`, but the
/// output is the collected `[Output]` from the structured-concurrency group.
struct TaskGroupLogic<Output: Sendable & Equatable>: ActorLogic {
    struct State: Sendable, Equatable {}

    let logic: TaskGroupActorLogic<Output>

    func initialState(input: SendableValue?) -> State { State() }
    func step(_ snapshot: State, on event: any Eventable) -> State { snapshot }
    func status(of snapshot: State) -> SnapshotStatus { .active }
    
    #if hasFeature(Embedded)
    func started<H: MachineHosting>(input: SendableValue?, host: isolated H) async -> Snapshot {
        initialState(input: input)
    }
    #endif

    func run(_ scope: ActorScope<State>) async -> (@Sendable () -> Void)? {
        let groupScope = TaskGroupScope(
            input: scope.input,
            sendToParent: scope.sendToParent,
            emit: scope.emit
        )
        let logic = self.logic
        let cleanup = AsyncCancelCleanup(onCancel: { await logic.onCancel(groupScope) })
        do {
            let outputs = try await runAsyncChildLogic(
                cleanup: cleanup,
                operation: { try await logic.run(groupScope) }
            )
            guard !Task.isCancelled else { return nil }
            scope.complete(SendableValue(outputs))
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            scope.fail(describeValue(error))
        }
        return nil
    }
}
