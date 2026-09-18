import Foundation
import Synchronization

final class RosterTestClock: Sendable {
    private struct Waiter {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var offset: Duration = .zero
        var waiters: [UUID: Waiter] = [:]
    }

    private let state = Mutex(State())

    var now: ContinuousClock.Instant {
        state.withLock { .now + $0.offset }
    }

    var pendingCount: Int {
        state.withLock { $0.waiters.count }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { state in
                    guard !Task.isCancelled else { return true }
                    state.waiters[id] = Waiter(deadline: .now + state.offset + duration, continuation: continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = self.state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let ready = state.withLock { state in
            state.offset += duration
            let now = ContinuousClock.now + state.offset
            let ready = state.waiters.filter { $0.value.deadline <= now }
            for id in ready.keys {
                state.waiters[id] = nil
            }
            return Array(ready.values)
        }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
