import Foundation

/// Caps the number of concurrent runs of an async operation. `withPermit` acquires a permit before running
/// `operation` and releases it after (on success, throw, or cancellation), so no more than `limit` operations
/// run at once and excess callers suspend FIFO until a permit frees up.
///
/// Deliberately named apart from `DuckoTestSupport.AsyncSemaphore` (a test-only `wait`/`signal` gate): that
/// type sits above DuckoCore and can't be depended on here.
public actor ConcurrencyLimiter {
    private var availablePermits: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init(limit: Int) {
        precondition(limit > 0, "ConcurrencyLimiter requires a positive limit")
        self.availablePermits = limit
    }

    /// Runs `operation` while holding a permit. `nonisolated` so `operation` runs in the caller's isolation
    /// domain — concurrently with other permit holders — rather than being serialized on this actor; only the
    /// quick permit accounting hops onto the actor. Throws `CancellationError` (from `acquire`) if cancelled
    /// while waiting for a permit, in which case no permit is taken and nothing is released.
    public nonisolated func withPermit<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await operation()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async throws {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Runs actor-isolated (via `#isolation`). Guard the early-cancellation trap: if the task is
                // already cancelled, `onCancel` fired before this appended a waiter, so resume here instead of
                // enqueuing a waiter nothing will ever wake.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
        // A permit handed over by `release()` can race a concurrent cancellation: `onCancel`'s cleanup runs in a
        // detached Task, unordered against `release()`, so `release()` may resume this waiter (granting a permit)
        // before `cancelWaiter` observes the cancellation. Re-check here — if we were granted a permit but the
        // task is cancelled, hand it back and throw rather than run cancelled work under a stolen permit.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            // Hand the permit directly to the next waiter (no increment): it never became free.
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
