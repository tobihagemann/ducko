import Testing

/// Pins the orchestration policy of `SubscriptionDance.subscribeAndApprove`
/// — idempotent timeout-skip, mutation-detection ordering, and fatal-wait
/// propagation — so a regression that silently re-introduces
/// `catch TestHarnessError.timeout {}` around the post-approve wait is
/// caught in credential-free runs. Top-level `enum` to opt out of the
/// parent suite's `.enabled(if:)` credentials trait.
enum SubscriptionDanceTests {
    @MainActor
    struct Orchestration {
        /// Pins the precondition that a failed `subscribe` short-circuits
        /// the rest of the dance. A regression that swallowed the throw
        /// (e.g. `try? await subscribe()`) would silently turn a failed
        /// roster mutation into a stuck dance that times out in
        /// `waitForRequest`.
        @Test
        func `subscribe failure rethrows and skips the rest of the dance`() async throws {
            let tracker = CallTracker()

            await #expect(throws: SentinelError.approveFailed) {
                try await SubscriptionDance.subscribeAndApprove(
                    requesterLabel: "alice",
                    approverLabel: "dave",
                    subscribe: {
                        await tracker.record(.subscribe)
                        throw SentinelError.approveFailed
                    },
                    waitForRequest: { await tracker.record(.waitForRequest) },
                    approve: { await tracker.record(.approve) },
                    awaitApproval: { await tracker.record(.awaitApproval) },
                    onMutationDetected: { await tracker.record(.onMutationDetected) }
                )
            }

            #expect(await tracker.calls == [.subscribe])
        }

        @Test
        func `waitForRequest timeout suppresses approve and awaitApproval`() async throws {
            let tracker = CallTracker()

            try await SubscriptionDance.subscribeAndApprove(
                requesterLabel: "alice",
                approverLabel: "dave",
                subscribe: { await tracker.record(.subscribe) },
                waitForRequest: { throw TestHarnessError.timeout },
                approve: { await tracker.record(.approve) },
                awaitApproval: { await tracker.record(.awaitApproval) },
                onMutationDetected: { await tracker.record(.onMutationDetected) }
            )

            #expect(await tracker.calls == [.subscribe])
        }

        @Test
        func `onMutationDetected fires after waitForRequest and before approve`() async throws {
            let tracker = CallTracker()

            try await SubscriptionDance.subscribeAndApprove(
                requesterLabel: "alice",
                approverLabel: "dave",
                subscribe: { await tracker.record(.subscribe) },
                waitForRequest: { await tracker.record(.waitForRequest) },
                approve: { await tracker.record(.approve) },
                awaitApproval: { await tracker.record(.awaitApproval) },
                onMutationDetected: { await tracker.record(.onMutationDetected) }
            )

            #expect(await tracker.calls == [
                .subscribe,
                .waitForRequest,
                .onMutationDetected,
                .approve,
                .awaitApproval
            ])
        }

        /// Pins the narrowness of the `catch TestHarnessError.timeout` in
        /// `subscribeAndApprove`. A regression that broadens it to `catch { … }`
        /// would turn real harness/event-stream failures (stream closure,
        /// router cancellation) into false-green "already subscribed" skips.
        @Test
        func `non-timeout waitForRequest failure propagates and skips approve`() async throws {
            let tracker = CallTracker()

            await #expect(throws: TestHarnessError.streamClosed) {
                try await SubscriptionDance.subscribeAndApprove(
                    requesterLabel: "alice",
                    approverLabel: "dave",
                    subscribe: { await tracker.record(.subscribe) },
                    waitForRequest: {
                        await tracker.record(.waitForRequest)
                        throw TestHarnessError.streamClosed
                    },
                    approve: { await tracker.record(.approve) },
                    awaitApproval: { await tracker.record(.awaitApproval) },
                    onMutationDetected: { await tracker.record(.onMutationDetected) }
                )
            }

            #expect(await tracker.calls == [.subscribe, .waitForRequest])
        }

        @Test
        func `approve failure rethrows and skips awaitApproval`() async throws {
            let tracker = CallTracker()

            await #expect(throws: SentinelError.approveFailed) {
                try await SubscriptionDance.subscribeAndApprove(
                    requesterLabel: "alice",
                    approverLabel: "dave",
                    subscribe: { await tracker.record(.subscribe) },
                    waitForRequest: { await tracker.record(.waitForRequest) },
                    approve: {
                        await tracker.record(.approve)
                        throw SentinelError.approveFailed
                    },
                    awaitApproval: { await tracker.record(.awaitApproval) },
                    onMutationDetected: { await tracker.record(.onMutationDetected) }
                )
            }

            #expect(await tracker.calls == [
                .subscribe,
                .waitForRequest,
                .onMutationDetected,
                .approve
            ])
        }

        @Test
        func `awaitApproval timeout propagates instead of being silently swallowed`() async throws {
            let tracker = CallTracker()

            await #expect(throws: TestHarnessError.timeout) {
                try await SubscriptionDance.subscribeAndApprove(
                    requesterLabel: "alice",
                    approverLabel: "dave",
                    subscribe: { await tracker.record(.subscribe) },
                    waitForRequest: { await tracker.record(.waitForRequest) },
                    approve: { await tracker.record(.approve) },
                    awaitApproval: {
                        await tracker.record(.awaitApproval)
                        throw TestHarnessError.timeout
                    },
                    onMutationDetected: { await tracker.record(.onMutationDetected) }
                )
            }

            #expect(await tracker.calls == [
                .subscribe,
                .waitForRequest,
                .onMutationDetected,
                .approve,
                .awaitApproval
            ])
        }
    }
}

private enum SubscriptionDanceCall: Equatable {
    case subscribe
    case waitForRequest
    case onMutationDetected
    case approve
    case awaitApproval
}

private actor CallTracker {
    private(set) var calls: [SubscriptionDanceCall] = []

    func record(_ call: SubscriptionDanceCall) {
        calls.append(call)
    }
}

private enum SentinelError: Error, Equatable {
    case approveFailed
}
