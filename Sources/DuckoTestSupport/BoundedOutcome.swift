private actor OutcomeBox {
    private(set) var result: Result<Void, any Error>?

    func finish(_ result: Result<Void, any Error>) {
        self.result = result
    }
}

/// Runs `operation` in an unstructured task and waits up to `timeout` for it to finish, so an await that ignores
/// cancellation can't hang the test. Returns `nil` when the operation is still running at the deadline, and leaves it
/// running.
public func boundedOutcome(
    timeout: Duration = .seconds(2),
    of operation: @escaping @Sendable () async throws -> Void
) async throws -> Result<Void, any Error>? {
    let box = OutcomeBox()
    Task {
        do {
            try await operation()
            await box.finish(.success(()))
        } catch {
            await box.finish(.failure(error))
        }
    }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let result = await box.result { return result }
        try await Task.sleep(for: .milliseconds(20))
    }
    return await box.result
}
