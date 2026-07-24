#if hasFeature(Embedded)
// Embedded Swift does not implicitly import the concurrency module the way full Swift does.
// Needed here for `Task.value`, reached through `currentTask()` rather than by name.
import _Concurrency
#endif

final class AsyncCancelCleanup: Sendable {
    private let taskState: CancelTaskState

    init(onCancel: @escaping @Sendable () async -> Void) {
        self.taskState = CancelTaskState(onCancel: onCancel)
    }

    func schedule() {
        taskState.schedule()
    }

    func wait() async {
        await taskState.currentTask()?.value
    }
}
