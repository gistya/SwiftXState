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
