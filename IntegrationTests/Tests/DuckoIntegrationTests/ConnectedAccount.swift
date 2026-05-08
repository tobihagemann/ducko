import DuckoXMPP
import Foundation

/// A connected XMPP account scoped to a `TestHarness`.
///
/// Thin facade over `EventRouter`: each `waitForEvent` / `collectEvents` call
/// allocates a fresh `UUID` and installs a one-shot waiter on the router via
/// `register`, with `withTaskCancellationHandler` propagating caller
/// `Task.cancel()` through `cancelWaiter`. The public API matches the prior
/// stream-based implementation so integration tests do not change.
@MainActor
final class ConnectedAccount {
    let accountID: UUID

    private unowned let router: EventRouter

    init(accountID: UUID, router: EventRouter) {
        self.accountID = accountID
        self.router = router
    }

    // MARK: - Event Waiting

    /// Waits for the first event matching `predicate`, or throws on timeout.
    func waitForEvent(
        matching predicate: @Sendable @escaping (XMPPEvent) -> Bool,
        timeout: Duration = TestTimeout.event
    ) async throws -> XMPPEvent {
        let waiterID = UUID()
        let accountID = accountID
        let router = router
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<XMPPEvent, any Error>) in
                let deliver: @MainActor (XMPPEvent) -> Bool = { event in
                    if predicate(event) {
                        continuation.resume(returning: event)
                        return true
                    }
                    return false
                }
                let cancel: @MainActor (TestHarnessError) -> Void = { error in
                    continuation.resume(throwing: error)
                }
                router.register(
                    accountID: accountID,
                    id: waiterID,
                    deliver: deliver,
                    cancel: cancel,
                    timeout: timeout
                )
            }
        } onCancel: {
            Task { @MainActor [router] in
                router.cancelWaiter(accountID: accountID, id: waiterID, error: .streamClosed)
            }
        }
    }

    /// Waits for the first event for which `extract` returns non-nil, returning
    /// the extracted payload. Lets tests destructure event payloads in one step
    /// instead of matching then re-`guard case let`-ing outside the closure.
    ///
    /// The explicit `extracting:` label disambiguates this overload from
    /// `waitForEvent(matching:)` at trailing-closure call sites where closure
    /// return type alone would leave the resolution fragile.
    func waitForEvent<T: Sendable>(
        extracting extract: @Sendable @escaping (XMPPEvent) -> T?,
        timeout: Duration = TestTimeout.event
    ) async throws -> T {
        let waiterID = UUID()
        let accountID = accountID
        let router = router
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                let deliver: @MainActor (XMPPEvent) -> Bool = { event in
                    if let extracted = extract(event) {
                        continuation.resume(returning: extracted)
                        return true
                    }
                    return false
                }
                let cancel: @MainActor (TestHarnessError) -> Void = { error in
                    continuation.resume(throwing: error)
                }
                router.register(
                    accountID: accountID,
                    id: waiterID,
                    deliver: deliver,
                    cancel: cancel,
                    timeout: timeout
                )
            }
        } onCancel: {
            Task { @MainActor [router] in
                router.cancelWaiter(accountID: accountID, id: waiterID, error: .streamClosed)
            }
        }
    }

    // periphery:ignore - reserved for multi-event protocol tests
    /// Collects every event up to and including the one that satisfies `predicate`.
    func collectEvents(
        until predicate: @Sendable @escaping (XMPPEvent) -> Bool,
        timeout: Duration = TestTimeout.event
    ) async throws -> [XMPPEvent] {
        let waiterID = UUID()
        let accountID = accountID
        let router = router
        let box = CollectorBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[XMPPEvent], any Error>) in
                let deliver: @MainActor (XMPPEvent) -> Bool = { event in
                    box.collected.append(event)
                    if predicate(event) {
                        continuation.resume(returning: box.collected)
                        return true
                    }
                    return false
                }
                let cancel: @MainActor (TestHarnessError) -> Void = { error in
                    continuation.resume(throwing: error)
                }
                router.register(
                    accountID: accountID,
                    id: waiterID,
                    deliver: deliver,
                    cancel: cancel,
                    timeout: timeout
                )
            }
        } onCancel: {
            Task { @MainActor [router] in
                router.cancelWaiter(accountID: accountID, id: waiterID, error: .streamClosed)
            }
        }
    }

    /// Polls `condition` on the MainActor until it returns true, or throws on timeout.
    ///
    /// Use this for service-state assertions: `onExternalEvent` fires before the
    /// internal service handlers (which run in their own `Task { @MainActor in ... }`),
    /// so a raw event wait does not guarantee the service has processed the event.
    func waitForCondition(
        _ condition: @MainActor @escaping () async -> Bool,
        timeout: Duration = TestTimeout.event,
        pollInterval: Duration = .milliseconds(100)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: pollInterval)
        }
        if await condition() { return }
        throw TestHarnessError.timeout
    }
}

/// Mutable accumulator captured by `collectEvents`'s `deliver`/`cancel`
/// closures. Reference type so the two closures share state. Freed when the
/// router drops the waiter (success, timeout, caller cancel, or teardown).
@MainActor
private final class CollectorBox {
    var collected: [XMPPEvent] = []
}
