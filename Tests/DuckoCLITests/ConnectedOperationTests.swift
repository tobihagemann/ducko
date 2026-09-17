import Testing
@testable import DuckoCLI

@MainActor
struct ConnectedOperationTests {
    enum Stage: String, CaseIterable {
        case connect, ready, operation
    }

    private enum FixtureError: Error {
        case failure
    }

    @Test(arguments: [false, true])
    func `success and early return await teardown`(earlyReturn: Bool) async throws {
        var calls: [String] = []
        let result: Int? = try await ConnectedOperation.run(
            connect: { calls.append("connect") },
            ready: { calls.append("ready") },
            operation: {
                calls.append("operation")
                if earlyReturn { return nil }
                return 42
            },
            teardown: {
                calls.append("teardown")
                await Task.yield()
                calls.append("finished")
            }
        )
        #expect(result == (earlyReturn ? nil : 42))
        #expect(calls == ["connect", "ready", "operation", "teardown", "finished"])
    }

    @Test(arguments: Stage.allCases)
    func `failure at every owned stage awaits one teardown`(stage: Stage) async {
        var calls: [String] = []
        await #expect(throws: FixtureError.self) {
            try await ConnectedOperation.run(
                connect: {
                    calls.append("connect")
                    if stage == .connect { throw FixtureError.failure }
                },
                ready: {
                    calls.append("ready")
                    if stage == .ready { throw FixtureError.failure }
                },
                operation: {
                    calls.append("operation")
                    throw FixtureError.failure
                },
                teardown: {
                    calls.append("teardown")
                    await Task.yield()
                    calls.append("finished")
                }
            )
        }
        let expected = switch stage {
        case .connect: ["connect"]
        case .ready: ["connect", "ready"]
        case .operation: ["connect", "ready", "operation"]
        }
        #expect(calls == expected + ["teardown", "finished"])
    }

    @Test(arguments: Stage.allCases)
    func `cancelling a suspended stage awaits teardown`(stage: Stage) async throws {
        let (entered, continuation) = AsyncStream.makeStream(of: Void.self)
        var calls: [String] = []
        let task = Task {
            try await ConnectedOperation.run(
                connect: {
                    calls.append("connect")
                    if stage == .connect {
                        continuation.yield()
                        try await Task.sleep(for: .seconds(60))
                    }
                },
                ready: {
                    calls.append("ready")
                    if stage == .ready {
                        continuation.yield()
                        try await Task.sleep(for: .seconds(60))
                    }
                },
                operation: {
                    calls.append("operation")
                    continuation.yield()
                    try await Task.sleep(for: .seconds(60))
                },
                teardown: {
                    calls.append("teardown")
                    await Task.yield()
                    calls.append("finished")
                }
            )
        }
        defer {
            task.cancel()
            continuation.finish()
        }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls.suffix(2) == ["teardown", "finished"])
        #expect(calls.filter { $0 == "teardown" }.count == 1)
    }

    @Test func `cancellation before connect still finishes ownership cleanup`() async {
        var calls: [String] = []
        let task = Task {
            try await ConnectedOperation.run(
                connect: { calls.append("connect") },
                ready: { calls.append("ready") },
                operation: { calls.append("operation") },
                teardown: { calls.append("teardown") }
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls == ["teardown"])
    }
}
