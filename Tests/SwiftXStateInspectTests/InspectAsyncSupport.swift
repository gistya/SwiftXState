import Foundation

/// Polls `condition` until it returns `true` or `timeout` elapses, returning
/// the final result. The bridge publishes over the transport on detached tasks
/// with no completion callback to await, so tests wait for the recorded side
/// effect to appear rather than sleeping for a fixed duration and hoping it
/// landed in time (which races under parallel load). The wait ends the moment
/// the condition holds, so it is as fast as the work allows and only the
/// timeout bounds a genuine failure.
@discardableResult
func waitUntil(
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(2),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: pollInterval)
    }
    return await condition()
}
