import Foundation

/// Owns an actor's delayed-event timers — the schedule behind `after:` transitions and delayed
/// `raise` / `sendTo`. Extracted from `Actor` so the same timer behaviour can back any actor
/// runtime (the generics refactor's `StateActor` will reuse it).
///
/// Accessed only under the owning actor's isolation; timer callbacks hop back to the owner before
/// touching the scheduler, so it never needs its own lock.
final class DelayScheduler {
    private var timers: [String: TimeoutHandle] = [:]
    private let clock: any Clock

    init(clock: any Clock) { self.clock = clock }

    /// Schedules `fire` after `delay` ms under `timerId`, replacing any existing timer with that id.
    func schedule(_ timerId: String, delay: Int, _ fire: @escaping @Sendable () -> Void) {
        cancel(timerId)
        timers[timerId] = clock.setTimeout(fire, delay: delay)
    }

    /// Cancels and clears a scheduled timer (no-op if there's nothing under `timerId`).
    func cancel(_ timerId: String) {
        guard let handle = timers.removeValue(forKey: timerId) else { return }
        clock.clearTimeout(handle)
    }

    /// Drops a fired timer's bookkeeping. The callback has already run, so no `clearTimeout` is
    /// needed — this just removes the now-stale entry (mirrors the old in-actor `removeValue`).
    func didFire(_ timerId: String) {
        timers.removeValue(forKey: timerId)
    }
}
