import DuckoXMPP
import Foundation
import Testing

/// Deterministic coverage for `EventRouter` and `ConnectedAccount`'s
/// cancellation-safe waiter registry. Pins:
///
/// - One-shot waiter resume on predicate match.
/// - Per-account FIFO gap buffer (consume-on-iterate so a stale event
///   cannot satisfy a later same-predicate wait).
/// - Per-waiter timeout fires `.timeout`.
/// - Caller `Task.cancel()` propagates as `.streamClosed`.
/// - Install-vs-cancel race tombstone path.
/// - The canonical reproducer for the original cancellation-poisoning bug
///   (timeout in one wait must not poison subsequent waits).
/// - Overlapping predicates broadcast (concurrent waiters).
/// - Stale-replay drain (sequential same-predicate).
/// - Mixed `collectEvents` + `waitForEvent` broadcast (cross-modal).
/// - `cancelAllWaiters` drains every account.
/// - Cross-account isolation.
///
/// Declared as a top-level `enum` so the suite does not inherit
/// `DuckoIntegrationTests`'s `.enabled(if: TestCredentials.isAvailable)`
/// trait — the registry has no live-server dependency and must run on any
/// developer or CI environment.
enum EventRouterTests {
    // MARK: - Direct router tests

    @MainActor
    @Suite(.timeLimit(.minutes(1)))
    struct DirectRouter {
        @Test
        func `register installs waiter and dispatch resolves it on predicate match`() async {
            let router = EventRouter()
            let accountID = UUID()
            let waiterID = UUID()
            let observer = WaiterObserver()

            router.register(
                accountID: accountID,
                id: waiterID,
                deliver: { event in
                    observer.deliveredEvents.append(event)
                    if case .rosterLoaded = event {
                        observer.resolved = true
                        return true
                    }
                    return false
                },
                cancel: { error in observer.cancelError = error },
                timeout: .seconds(60)
            )
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 1)

            router.dispatch(.disconnected(.requested), accountID: accountID)
            await yieldUntil { observer.deliveredEvents.count == 1 }
            #expect(observer.resolved == false)
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 1)

            router.dispatch(.rosterLoaded([]), accountID: accountID)
            await yieldUntil { observer.resolved }
            #expect(observer.deliveredEvents.count == 2)
            #expect(observer.cancelError == nil)
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)
        }

        @Test
        func `replay buffer delivers events that arrived before register`() {
            let router = EventRouter()
            let accountID = UUID()
            let waiterID = UUID()
            let observer = WaiterObserver()

            // Two events arrive while no waiter is active — both buffered.
            router.dispatch(.disconnected(.requested), accountID: accountID)
            router.dispatch(.rosterLoaded([]), accountID: accountID)

            router.register(
                accountID: accountID,
                id: waiterID,
                deliver: { event in
                    observer.deliveredEvents.append(event)
                    if case .rosterLoaded = event {
                        observer.resolved = true
                        return true
                    }
                    return false
                },
                cancel: { error in observer.cancelError = error },
                timeout: .seconds(60)
            )

            // Both replayed; the second resolves the waiter.
            #expect(observer.resolved)
            #expect(observer.deliveredEvents.count == 2)
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)
        }

        @Test
        func `cancelWaiter on installed waiter resumes-throw and clears the slot`() {
            let router = EventRouter()
            let accountID = UUID()
            let waiterID = UUID()
            let observer = WaiterObserver()

            router.register(
                accountID: accountID,
                id: waiterID,
                deliver: { _ in observer.deliveredEvents.append(.rosterLoaded([])); return false },
                cancel: { error in observer.cancelError = error },
                timeout: .seconds(60)
            )
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 1)

            router.cancelWaiter(accountID: accountID, id: waiterID, error: .streamClosed)
            #expect(observer.cancelError == .streamClosed)
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)
        }

        @Test
        func `tombstone path: cancelWaiter before register routes through cancel closure`() {
            let router = EventRouter()
            let accountID = UUID()
            let waiterID = UUID()
            let observer = WaiterObserver()

            // Cancel first — stamps a tombstone.
            router.cancelWaiter(accountID: accountID, id: waiterID, error: .streamClosed)

            // Now register: tombstone consumed atomically; cancel closure fires;
            // waiter never installed.
            router.register(
                accountID: accountID,
                id: waiterID,
                deliver: { _ in observer.deliveredEvents.append(.rosterLoaded([])); return true },
                cancel: { error in observer.cancelError = error },
                timeout: .seconds(60)
            )

            #expect(observer.cancelError == .streamClosed)
            #expect(observer.deliveredEvents.isEmpty)
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)
        }

        @Test
        func `dispatch broadcasts to overlapping waiters; declines drop with the consumer`() async {
            let router = EventRouter()
            let accountID = UUID()
            let observerA = WaiterObserver()
            let observerB = WaiterObserver()
            let idA = UUID()
            let idB = UUID()

            // A consumes `.rosterLoaded`; B consumes `.disconnected`.
            router.register(
                accountID: accountID,
                id: idA,
                deliver: { event in
                    observerA.deliveredEvents.append(event)
                    if case .rosterLoaded = event {
                        observerA.resolved = true
                        return true
                    }
                    return false
                },
                cancel: { error in observerA.cancelError = error },
                timeout: .seconds(60)
            )
            router.register(
                accountID: accountID,
                id: idB,
                deliver: { event in
                    observerB.deliveredEvents.append(event)
                    if case .disconnected = event {
                        observerB.resolved = true
                        return true
                    }
                    return false
                },
                cancel: { error in observerB.cancelError = error },
                timeout: .seconds(60)
            )
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 2)

            router.dispatch(.rosterLoaded([]), accountID: accountID)
            await yieldUntil { observerA.resolved }
            #expect(observerB.resolved == false)
            #expect(observerB.deliveredEvents.count == 1)
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 1)

            router.dispatch(.disconnected(.requested), accountID: accountID)
            await yieldUntil { observerB.resolved }
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)
        }

        @Test
        func `stale-replay drain: same predicate twice does not see the consumed event`() async {
            let router = EventRouter()
            let accountID = UUID()
            let observerA = WaiterObserver()
            let observerB = WaiterObserver()

            router.register(
                accountID: accountID,
                id: UUID(),
                deliver: { event in
                    observerA.deliveredEvents.append(event)
                    if case .rosterLoaded = event {
                        observerA.resolved = true
                        return true
                    }
                    return false
                },
                cancel: { error in observerA.cancelError = error },
                timeout: .seconds(60)
            )
            router.dispatch(.rosterLoaded([]), accountID: accountID)
            await yieldUntil { observerA.resolved }
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)

            // Second wait for `.rosterLoaded` — must NOT see the consumed event.
            router.register(
                accountID: accountID,
                id: UUID(),
                deliver: { event in
                    observerB.deliveredEvents.append(event)
                    if case .rosterLoaded = event {
                        observerB.resolved = true
                        return true
                    }
                    return false
                },
                cancel: { error in observerB.cancelError = error },
                timeout: .seconds(60)
            )
            #expect(observerB.resolved == false)
            #expect(observerB.deliveredEvents.isEmpty)
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 1)

            // Fresh dispatch resolves it.
            router.dispatch(.rosterLoaded([]), accountID: accountID)
            await yieldUntil { observerB.resolved }
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)
        }

        @Test
        func `cancelAllWaiters drains every account and clears the gap buffer`() {
            let router = EventRouter()
            defer { router.cancelAllWaiters() }
            let accountA = UUID()
            let accountB = UUID()
            let observerA = WaiterObserver()
            let observerB = WaiterObserver()

            router.register(
                accountID: accountA,
                id: UUID(),
                deliver: { _ in false },
                cancel: { error in observerA.cancelError = error },
                timeout: .seconds(60)
            )
            router.register(
                accountID: accountB,
                id: UUID(),
                deliver: { _ in false },
                cancel: { error in observerB.cancelError = error },
                timeout: .seconds(60)
            )
            // Stash a buffered event under a third account.
            router.dispatch(.disconnected(.requested), accountID: UUID())

            router.cancelAllWaiters()

            #expect(observerA.cancelError == .streamClosed)
            #expect(observerB.cancelError == .streamClosed)
            #expect(router.pendingWaiterCount(forAccountID: accountA) == 0)
            #expect(router.pendingWaiterCount(forAccountID: accountB) == 0)

            // Replay buffer cleared: a fresh waiter installed afterward sees nothing.
            let postObserver = WaiterObserver()
            router.register(
                accountID: accountA,
                id: UUID(),
                deliver: { event in postObserver.deliveredEvents.append(event); return false },
                cancel: { error in postObserver.cancelError = error },
                timeout: .seconds(60)
            )
            #expect(postObserver.deliveredEvents.isEmpty)
        }

        @Test
        func `dispatch on account A does not deliver to account B's waiter`() async {
            let router = EventRouter()
            defer { router.cancelAllWaiters() }
            let accountA = UUID()
            let accountB = UUID()
            let observerA = WaiterObserver()
            let observerB = WaiterObserver()

            router.register(
                accountID: accountA,
                id: UUID(),
                deliver: { event in
                    observerA.deliveredEvents.append(event)
                    return true
                },
                cancel: { error in observerA.cancelError = error },
                timeout: .seconds(60)
            )
            router.register(
                accountID: accountB,
                id: UUID(),
                deliver: { event in
                    observerB.deliveredEvents.append(event)
                    return true
                },
                cancel: { error in observerB.cancelError = error },
                timeout: .seconds(60)
            )

            router.dispatch(.rosterLoaded([]), accountID: accountA)
            await yieldUntil { observerA.deliveredEvents.count == 1 }
            #expect(observerB.deliveredEvents.isEmpty)
            #expect(router.pendingWaiterCount(forAccountID: accountB) == 1)
        }

        /// Pins the load-bearing race-guard at the top of `EventRouter.dispatch`:
        /// when a waiter is removed (here via `cancelWaiter`) between the
        /// synchronous `bucket` snapshot and the deferred `Task { @MainActor }`
        /// body, the deferred Task's `where self.waiters[acc]?[id] != nil`
        /// short-circuit must skip the `deliver` call. Without the guard,
        /// `deliver` would resume an already-resumed `CheckedContinuation` and
        /// the `CheckedContinuation` runtime would trap.
        @Test
        func `dispatch skips delivery when waiter cancelled before deferred Task runs`() async {
            let router = EventRouter()
            defer { router.cancelAllWaiters() }
            let accountID = UUID()
            let observer = WaiterObserver()
            let waiterID = UUID()

            router.register(
                accountID: accountID,
                id: waiterID,
                deliver: { event in
                    observer.deliveredEvents.append(event)
                    return true
                },
                cancel: { error in observer.cancelError = error },
                timeout: .seconds(60)
            )

            // Synchronous on MainActor: dispatch queues the deferred Task,
            // then cancelWaiter removes the waiter and resumes-throw — both
            // before any await yields the actor.
            router.dispatch(.rosterLoaded([]), accountID: accountID)
            router.cancelWaiter(accountID: accountID, id: waiterID, error: .streamClosed)

            await Task.yield()
            await Task.yield()

            #expect(observer.deliveredEvents.isEmpty)
            #expect(observer.cancelError == .streamClosed)
        }
    }

    // MARK: - ConnectedAccount facade tests

    @MainActor
    @Suite(.timeLimit(.minutes(1)))
    struct ConnectedAccountFacade {
        @Test
        func `waitForEvent matching resolves on first matching event`() async throws {
            let router = EventRouter()
            let accountID = UUID()
            let connected = ConnectedAccount(accountID: accountID, router: router)

            let task = Task {
                try await connected.waitForEvent(matching: { event in
                    if case .rosterLoaded = event { return true }
                    return false
                }, timeout: .seconds(10))
            }
            await yieldUntil { router.pendingWaiterCount(forAccountID: accountID) == 1 }

            router.dispatch(.disconnected(.requested), accountID: accountID)
            router.dispatch(.rosterLoaded([]), accountID: accountID)

            let event = try await task.value
            if case .rosterLoaded = event {
                // ok
            } else {
                Issue.record("expected .rosterLoaded, got \(event)")
            }
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)
        }

        @Test
        func `waitForEvent matching throws timeout when no event arrives`() async {
            let router = EventRouter()
            let accountID = UUID()
            let connected = ConnectedAccount(accountID: accountID, router: router)

            await #expect(throws: TestHarnessError.timeout) {
                _ = try await connected.waitForEvent(
                    matching: { _ in false },
                    timeout: .milliseconds(50)
                )
            }
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)
        }

        @Test
        func `waitForEvent matching throws streamClosed on caller Task cancel`() async throws {
            let router = EventRouter()
            let accountID = UUID()
            let connected = ConnectedAccount(accountID: accountID, router: router)

            let task = Task {
                try await connected.waitForEvent(
                    matching: { _ in false },
                    timeout: .seconds(60)
                )
            }
            await yieldUntil { router.pendingWaiterCount(forAccountID: accountID) == 1 }

            task.cancel()

            await #expect(throws: TestHarnessError.streamClosed) {
                _ = try await task.value
            }
            // Cancel hops via Task; allow the queued cancelWaiter to run before
            // observing the slot count.
            await yieldUntil { router.pendingWaiterCount(forAccountID: accountID) == 0 }
        }

        @Test
        func `waitForEvent extracting returns the extracted payload`() async throws {
            let router = EventRouter()
            let accountID = UUID()
            let connected = ConnectedAccount(accountID: accountID, router: router)

            let task = Task {
                try await connected.waitForEvent(extracting: { event -> Int? in
                    if case let .rosterLoaded(items) = event { return items.count }
                    return nil
                }, timeout: .seconds(10))
            }
            await yieldUntil { router.pendingWaiterCount(forAccountID: accountID) == 1 }

            router.dispatch(.disconnected(.requested), accountID: accountID)
            router.dispatch(.rosterLoaded([]), accountID: accountID)

            let count = try await task.value
            #expect(count == 0)
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)
        }

        @Test
        func `collectEvents accumulates until terminator and includes it`() async throws {
            let router = EventRouter()
            let accountID = UUID()
            let connected = ConnectedAccount(accountID: accountID, router: router)

            let task = Task {
                try await connected.collectEvents(until: { event in
                    if case .rosterLoaded = event { return true }
                    return false
                }, timeout: .seconds(10))
            }
            await yieldUntil { router.pendingWaiterCount(forAccountID: accountID) == 1 }

            router.dispatch(.disconnected(.requested), accountID: accountID)
            router.dispatch(.disconnected(.requested), accountID: accountID)
            router.dispatch(.rosterLoaded([]), accountID: accountID)

            let collected = try await task.value
            #expect(collected.count == 3)
            if case .rosterLoaded = collected.last {
                // ok
            } else {
                Issue.record("expected terminator .rosterLoaded at end, got \(String(describing: collected.last))")
            }
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)
        }

        @Test
        func `mixed collectEvents and waitForEvent both observe the same dispatch`() async throws {
            let router = EventRouter()
            let accountID = UUID()
            let connected = ConnectedAccount(accountID: accountID, router: router)

            let waitTask = Task {
                try await connected.waitForEvent(matching: { event in
                    if case .disconnected = event { return true }
                    return false
                }, timeout: .seconds(10))
            }
            let collectTask = Task {
                try await connected.collectEvents(until: { event in
                    if case .rosterLoaded = event { return true }
                    return false
                }, timeout: .seconds(10))
            }
            await yieldUntil { router.pendingWaiterCount(forAccountID: accountID) == 2 }

            router.dispatch(.disconnected(.requested), accountID: accountID)
            // After the .disconnected dispatch, the waitForEvent waiter has
            // resolved-and-removed. The collector remains, having appended the
            // event. Pin that ordering before the second dispatch.
            await yieldUntil { router.pendingWaiterCount(forAccountID: accountID) == 1 }

            router.dispatch(.rosterLoaded([]), accountID: accountID)

            let waitEvent = try await waitTask.value
            if case .disconnected = waitEvent {
                // ok
            } else {
                Issue.record("expected waitForEvent to resolve with .disconnected, got \(waitEvent)")
            }
            let collected = try await collectTask.value
            #expect(collected.count == 2)
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)
        }
    }

    // MARK: - Canonical reproducer

    @MainActor
    @Suite(.timeLimit(.minutes(1)))
    struct CanonicalReproducerSuite {
        /// The original cancellation-poisoning bug: a `waitForEvent` that
        /// timed out poisoned the shared per-account `AsyncStream`, so every
        /// later `waitForEvent` on the same account immediately threw
        /// `.streamClosed`. With the registry, an unrelated wait after a
        /// timeout must resolve cleanly.
        @Test
        func `timeout in one wait does not poison subsequent waits`() async throws {
            let router = EventRouter()
            let accountID = UUID()
            let connected = ConnectedAccount(accountID: accountID, router: router)

            // Waiter A times out.
            await #expect(throws: TestHarnessError.timeout) {
                _ = try await connected.waitForEvent(
                    matching: { _ in false },
                    timeout: .milliseconds(50)
                )
            }
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)

            // Waiter B with a different predicate must resolve cleanly.
            let task = Task {
                try await connected.waitForEvent(matching: { event in
                    if case .rosterLoaded = event { return true }
                    return false
                }, timeout: .seconds(10))
            }
            await yieldUntil { router.pendingWaiterCount(forAccountID: accountID) == 1 }

            router.dispatch(.rosterLoaded([]), accountID: accountID)

            let event = try await task.value
            if case .rosterLoaded = event {
                // ok
            } else {
                Issue.record("expected .rosterLoaded, got \(event)")
            }
            #expect(router.pendingWaiterCount(forAccountID: accountID) == 0)
        }
    }
}

// MARK: - Test helpers

/// Mutable accumulator for direct-router tests. Reference type so test
/// closures share state across the synchronous test body.
@MainActor
private final class WaiterObserver {
    var deliveredEvents: [XMPPEvent] = []
    var resolved = false
    var cancelError: TestHarnessError?
}

/// Yields the current task until `condition` is met. Used to deterministically
/// observe waiter installation without `Task.sleep`.
@MainActor
private func yieldUntil(_ condition: @MainActor () -> Bool) async {
    while !condition() {
        await Task.yield()
    }
}
