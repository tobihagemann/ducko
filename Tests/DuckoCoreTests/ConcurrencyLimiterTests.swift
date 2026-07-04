import DuckoTestSupport
import Testing
@testable import DuckoCore

private struct Boom: Error {}

struct ConcurrencyLimiterTests {
    @Test
    func `permit is released when the operation throws, so a later acquirer proceeds`() async throws {
        let limiter = DuckoCore.ConcurrencyLimiter(limit: 1)

        await #expect(throws: Boom.self) {
            try await limiter.withPermit { throw Boom() }
        }

        let proceeded = try await limiter.withPermit { true }
        #expect(proceeded)
    }

    @Test
    func `a task cancelled while waiting for a permit throws CancellationError without leaking the permit`() async throws {
        let limiter = DuckoCore.ConcurrencyLimiter(limit: 1)
        let holderAcquired = AsyncSemaphore()
        let releaseHolder = AsyncSemaphore()

        let holder = Task {
            try await limiter.withPermit {
                await holderAcquired.signal()
                await releaseHolder.wait()
            }
        }
        await holderAcquired.wait()

        // The only permit is held, so this waiter suspends acquiring one; cancelling it must surface a
        // CancellationError whether it was already enqueued or not yet.
        let waiter = Task { try await limiter.withPermit {} }
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }

        // Freeing the holder's permit must let a fresh acquirer proceed — proof the cancelled waiter leaked none.
        await releaseHolder.signal()
        try await holder.value
        let proceeded = try await limiter.withPermit { true }
        #expect(proceeded)
    }
}
