import Foundation

/// Polls `condition` at `interval` until it returns `true` or `timeout` elapses.
/// Cooperatively cancellable: returns `false` if the current task is cancelled
/// at any point — including if `Task.sleep` is cancelled during a poll gap.
///
/// The closure is `sending` so an isolated caller (e.g. `@MainActor`) can hand
/// ownership across to this nonisolated helper without a `@Sendable` annotation
/// or `@MainActor` coupling on the closure itself.
func pollUntil(
    _ condition: sending () async -> Bool,
    timeout: Duration,
    interval: Duration = .milliseconds(50)
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if Task.isCancelled { return false }
        if await condition() { return true }
        do {
            try await Task.sleep(for: interval)
        } catch {
            return false
        }
    }
    if Task.isCancelled { return false }
    return await condition()
}
