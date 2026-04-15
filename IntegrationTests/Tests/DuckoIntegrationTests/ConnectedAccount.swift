import DuckoXMPP
import Foundation

/// A connected XMPP account scoped to a `TestHarness`.
///
/// Wraps a single account inside the harness's shared `AppEnvironment` and
/// owns the per-account event stream that the harness's external-event router
/// feeds via the `accountID` filter.
@MainActor
final class ConnectedAccount {
    let accountID: UUID

    private let eventStream: AsyncStream<XMPPEvent>

    init(accountID: UUID, eventStream: AsyncStream<XMPPEvent>) {
        self.accountID = accountID
        self.eventStream = eventStream
    }

    // MARK: - Event Waiting

    /// Waits for the first event matching `predicate`, or throws on timeout.
    func waitForEvent(
        matching predicate: @Sendable @escaping (XMPPEvent) -> Bool,
        timeout: Duration = TestTimeout.event
    ) async throws -> XMPPEvent {
        try await race(timeout: timeout) { stream in
            for await event in stream where predicate(event) {
                return event
            }
            throw TestHarnessError.streamClosed
        }
    }

    // periphery:ignore - reserved for multi-event protocol tests
    /// Collects every event up to and including the one that satisfies `predicate`.
    func collectEvents(
        until predicate: @Sendable @escaping (XMPPEvent) -> Bool,
        timeout: Duration = TestTimeout.event
    ) async throws -> [XMPPEvent] {
        try await race(timeout: timeout) { stream in
            var collected: [XMPPEvent] = []
            for await event in stream {
                collected.append(event)
                if predicate(event) { return collected }
            }
            throw TestHarnessError.streamClosed
        }
    }

    /// Polls `condition` on the MainActor until it returns true, or throws on timeout.
    ///
    /// Use this for service-state assertions: `onExternalEvent` fires before the
    /// internal service handlers (which run in their own `Task { @MainActor in ... }`),
    /// so a raw event wait does not guarantee the service has processed the event.
    func waitForCondition(
        _ condition: @MainActor @escaping () -> Bool,
        timeout: Duration = TestTimeout.event,
        pollInterval: Duration = .milliseconds(100)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: pollInterval)
        }
        if condition() { return }
        throw TestHarnessError.timeout
    }

    // MARK: - Private

    /// Races a stream-consumer task against a timeout sleep, returning the first
    /// successful result or throwing `TestHarnessError.timeout`.
    private func race<Result: Sendable>(
        timeout: Duration,
        consume: @Sendable @escaping (AsyncStream<XMPPEvent>) async throws -> Result
    ) async throws -> Result {
        let stream = eventStream
        return try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                try await consume(stream)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestHarnessError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw TestHarnessError.streamClosed
            }
            return result
        }
    }
}
