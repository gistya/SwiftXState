#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
import os
#else
import Synchronization
#endif

final class CancelTaskState: Sendable {
    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
    private let lock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    #else
    private let lock = Mutex<Task<Void, Never>?>(nil)
    #endif
    private let onCancel: @Sendable () async -> Void

    init(onCancel: @escaping @Sendable () async -> Void) {
        self.onCancel = onCancel
    }

    func schedule() {
        lock.withLock { task in
            if task == nil {
                task = Task { await onCancel() }
            }
        }
    }

    func currentTask() -> Task<Void, Never>? {
        lock.withLock { $0 }
    }
}
