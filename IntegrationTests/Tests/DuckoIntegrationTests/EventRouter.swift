import DuckoXMPP
import Foundation

/// Routes XMPP events to per-account `AsyncStream` continuations.
///
/// Global-actor-isolated classes (`@MainActor final class`) are `Sendable`
/// because all access goes through the actor, so the harness can capture this
/// in the `@Sendable` `onExternalEvent` closure and hop back onto the MainActor
/// via `MainActor.assumeIsolated` to dispatch without a lock.
@MainActor
final class EventRouter {
    private var routes: [UUID: AsyncStream<XMPPEvent>.Continuation] = [:]

    func register(accountID: UUID, continuation: AsyncStream<XMPPEvent>.Continuation) {
        // Finish any prior continuation so a stale consumer terminates instead of
        // hanging until its timeout fires.
        routes[accountID]?.finish()
        routes[accountID] = continuation
    }

    func unregister(accountID: UUID) {
        routes[accountID]?.finish()
        routes[accountID] = nil
    }

    func dispatch(_ event: XMPPEvent, accountID: UUID) {
        routes[accountID]?.yield(event)
    }

    func finishAll() {
        for continuation in routes.values {
            continuation.finish()
        }
        routes.removeAll()
    }
}
