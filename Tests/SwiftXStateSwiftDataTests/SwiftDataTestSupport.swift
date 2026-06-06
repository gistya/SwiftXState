#if SWIFTXSTATE_APPLE_SWIFTDATA
import Foundation

/// Serializes SwiftData `ModelContainer` creation across the whole test process.
///
/// CoreData (under SwiftData) is not safe to *create* persistent stores from
/// multiple threads at once: under the parallel test harness the first-connect
/// path (`-[NSSQLiteConnection createTriggersForEntities:]` →
/// `-[__NSDictionaryM setObject:forKey:]`) mutates shared model state without
/// locking and segfaults, taking the whole process down — and with it whatever
/// unrelated test happened to be mid-flight (which is why the crash surfaces on
/// a different, random test each run). Building each container inside this lock
/// constructs stores one at a time; the finished, independent in-memory
/// containers are then safe to use concurrently.
private let swiftDataContainerCreationLock = NSLock()

/// Runs `body` (a `ModelContainer` construction) while holding the process-wide
/// container-creation lock.
func withSwiftDataContainerLock<T>(_ body: () throws -> T) rethrows -> T {
    swiftDataContainerCreationLock.lock()
    defer { swiftDataContainerCreationLock.unlock() }
    return try body()
}
#endif
