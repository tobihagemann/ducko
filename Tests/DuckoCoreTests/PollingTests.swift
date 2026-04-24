import Testing
@testable import DuckoCore

enum PollingTests {
    struct SuccessCases {
        @Test func `returns true when condition is immediately true`() async {
            let result = await pollUntil({ true }, timeout: .seconds(1), interval: .milliseconds(10))
            #expect(result == true)
        }

        @Test func `returns true when condition becomes true within budget`() async {
            let start = ContinuousClock.now
            var calls = 0
            let result = await pollUntil(
                {
                    calls += 1
                    return calls >= 3
                },
                timeout: .seconds(1),
                interval: .milliseconds(20)
            )
            let elapsed = start.duration(to: ContinuousClock.now)
            #expect(result == true)
            #expect(calls >= 3)
            // Three probes × 20 ms interval → well below the 1 s deadline.
            #expect(elapsed < .milliseconds(500))
        }
    }

    struct TimeoutCases {
        @Test func `returns false when condition is always false and deadline elapses`() async {
            let start = ContinuousClock.now
            let result = await pollUntil(
                { false },
                timeout: .milliseconds(100),
                interval: .milliseconds(10)
            )
            let elapsed = start.duration(to: ContinuousClock.now)
            #expect(result == false)
            // Should be at least the timeout; some slack for scheduling.
            #expect(elapsed >= .milliseconds(90))
        }

        @Test func `final condition evaluation runs even when loop body is skipped`() async {
            // A zero timeout skips the while-loop body entirely; the post-loop
            // re-evaluation is the only call. Time-independent by construction.
            var calls = 0
            let result = await pollUntil(
                {
                    calls += 1
                    return true
                },
                timeout: .zero,
                interval: .milliseconds(10)
            )
            #expect(result == true)
            #expect(calls == 1)
        }
    }

    struct CancellationCases {
        @Test func `returns false when the surrounding task is cancelled before starting`() async {
            let task = Task {
                await pollUntil({ false }, timeout: .seconds(10), interval: .milliseconds(50))
            }
            task.cancel()
            let result = await task.value
            #expect(result == false)
        }

        @Test func `returns false when the surrounding task is cancelled during sleep`() async {
            let task = Task {
                await pollUntil({ false }, timeout: .seconds(10), interval: .milliseconds(200))
            }
            try? await Task.sleep(for: .milliseconds(50))
            task.cancel()
            let start = ContinuousClock.now
            let result = await task.value
            let elapsed = start.duration(to: ContinuousClock.now)
            #expect(result == false)
            // The cancellation should short-circuit well before the 10 s timeout.
            #expect(elapsed < .seconds(1))
        }
    }
}
