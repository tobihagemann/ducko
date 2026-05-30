import DuckoTestSupport
import Testing

/// Direct tests for the `awaitSentResponse` helper in `XMPPTestHelpers.swift`.
/// It is exercised indirectly by every module test that uses it, but pinned here
/// directly because a regression would silently mask a missing response.
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

    struct ZeroTimeout {
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
    }
}
