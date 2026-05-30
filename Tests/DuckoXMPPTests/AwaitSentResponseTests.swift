import DuckoTestSupport
import Testing

/// Direct tests for the `awaitSentResponse` helper in `XMPPTestHelpers.swift`.
/// The helper is exercised indirectly by every module test that uses it, but a
/// regression in the scanned-offset bookkeeping or the post-deadline scan would
/// either reintroduce timing flake or silently miss late-arriving responses.
enum AwaitSentResponseTests {
    private static func connectedMock() async throws -> MockTransport {
        let mock = MockTransport()
        try await mock.connect(host: "example.com", port: 5222)
        return mock
    }

    struct MatchCases {
        @Test func `returns the first outgoing bytes whose payload matches the predicate`() async throws {
            let mock = try await connectedMock()
            let sender = Task {
                try? await Task.sleep(for: .milliseconds(50))
                try? await mock.send(Array("<iq id='r1' type='result'/>".utf8))
            }
            let result = await awaitSentResponse(
                on: mock,
                afterReceiving: "<iq id='r1' type='get'/>",
                matching: { $0.contains("id='r1'") && $0.contains("result") },
                timeout: .seconds(2)
            )
            _ = await sender.value
            #expect(result?.contains("result") == true)
        }

        @Test func `scans multiple outgoing sends and picks the predicate match`() async throws {
            let mock = try await connectedMock()
            let sender = Task {
                try? await Task.sleep(for: .milliseconds(40))
                try? await mock.send(Array("<other/>".utf8))
                try? await mock.send(Array("<target kind='B'/>".utf8))
                try? await mock.send(Array("<noise/>".utf8))
            }
            let result = await awaitSentResponse(
                on: mock,
                afterReceiving: "<trigger/>",
                matching: { $0.contains("target") && $0.contains("kind='B'") },
                timeout: .seconds(2)
            )
            _ = await sender.value
            #expect(result?.contains("target") == true)
        }
    }

    struct NoMatchCases {
        @Test func `returns nil when the predicate is never satisfied`() async throws {
            let mock = try await connectedMock()
            let start = ContinuousClock.now
            let result = await awaitSentResponse(
                on: mock,
                afterReceiving: "<x/>",
                matching: { _ in false },
                timeout: .milliseconds(100)
            )
            let elapsed = start.duration(to: ContinuousClock.now)
            #expect(result == nil)
            // Helper should observe the deadline, not over-sleep dramatically.
            #expect(elapsed >= .milliseconds(90))
        }

        @Test func `clearSentBytes isolates previous outgoing bytes from the predicate`() async throws {
            let mock = try await connectedMock()
            // Pre-populate the mock with bytes that *would* match the predicate.
            // The helper must clear these before scanning; otherwise it would
            // silently return stale bytes from a prior test phase.
            try await mock.send(Array("<stale kind='leftover'/>".utf8))
            let result = await awaitSentResponse(
                on: mock,
                afterReceiving: "<x/>",
                matching: { $0.contains("stale") },
                timeout: .milliseconds(100)
            )
            #expect(result == nil)
        }
    }

    struct PostLoopScan {
        @Test func `clear-before-scan isolates previously-sent bytes even on zero timeout`() async throws {
            let mock = try await connectedMock()
            try await mock.send(Array("<priorByte/>".utf8))
            let result = await awaitSentResponse(
                on: mock,
                afterReceiving: "<trigger/>",
                matching: { $0.contains("priorByte") },
                timeout: .zero
            )
            // The helper clears sentBytes as its first step, so `priorByte`
            // must NOT match.
            #expect(result == nil)
        }

        @Test func `the final scan returns a stanza appended after the last in-loop scan`() async throws {
            // The helper scans `sentBytes` on a fixed ~25 ms cadence until the deadline, then runs one final
            // scan. This exercises that final scan: the reply lands ~20 ms before the deadline — past the last
            // in-loop scan (~25 ms before the deadline) under normal timing, so the final scan is what returns
            // it. The guard is timing-based, not deterministic: a late-waking in-loop scan can also catch the
            // reply, so deleting the final scan does not *guarantee* a failure here. A deterministic guard would
            // need a timing seam in `awaitSentResponse` itself, which its single-consumer signature deliberately
            // avoids.
            //
            // Drive the wait off the same `ContinuousClock` with short poll-sleeps (not one long sleep) so heavy
            // parallel load — which inflates a single `Task.sleep` and could overshoot the deadline — can't push
            // the send past the final scan and turn the result into a spurious `nil`.
            let mock = try await connectedMock()
            let timeout = Duration.milliseconds(300)
            let start = ContinuousClock.now
            let sendAt = start.advanced(by: timeout - .milliseconds(20))
            let sender = Task {
                while ContinuousClock.now < sendAt {
                    try? await Task.sleep(for: .milliseconds(4))
                }
                try? await mock.send(Array("<late kind='final'/>".utf8))
            }
            let result = await awaitSentResponse(
                on: mock,
                afterReceiving: "<trigger/>",
                matching: { $0.contains("late") && $0.contains("kind='final'") },
                timeout: timeout
            )
            _ = await sender.value
            #expect(result?.contains("late") == true)
        }
    }
}
