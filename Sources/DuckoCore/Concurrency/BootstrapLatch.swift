import Synchronization

/// Outcome of a `BootstrapLatch.runOnce(_:)` call: whether this caller won the latch and ran
/// the work (`ran`) or arrived after it was already claimed and skipped (`skipped`).
public enum BootstrapRunResult: Sendable, Equatable {
    case ran
    case skipped
}

/// First-call-wins idempotency latch, generalizing the logging-bootstrap guard that
/// `LoggingConfiguration.bootstrap()` wraps around the process-global `LoggingSystem.bootstrap`
/// (which traps on a second invocation).
///
/// The winning caller runs `work` *outside* the internal mutex (`Mutex` is not recursive, so
/// running it under the lock would deadlock a re-entrant call). Concurrent callers that arrive
/// after the latch is claimed return `.skipped` without waiting for the winning caller's `work`
/// to finish. Use this for first-call-wins idempotency, not as a completion barrier: `.skipped`
/// means another caller has *claimed* the work, not that the work has *completed*.
public final class BootstrapLatch: Sendable {
    private let started = Mutex(false)

    public init() {}

    /// Runs `work` exactly once across all callers.
    @discardableResult
    public func runOnce(_ work: @Sendable () -> Void) -> BootstrapRunResult {
        let won = started.withLock { isStarted in
            guard !isStarted else { return false }
            isStarted = true
            return true
        }
        guard won else { return .skipped }
        work()
        return .ran
    }
}
