import NIOCore

extension EventLoopFuture where Value: Sendable {
    func get(timeout: Duration, ignoringCancellation: Bool = false) async throws -> Value {
        let result = eventLoop.makePromise(of: Value.self)
        cascade(to: result)
        let deadline = eventLoop.scheduleTask(in: TimeAmount(timeout)) {
            result.fail(XMPPClientError.timeout)
        }
        defer { deadline.cancel() }
        if ignoringCancellation { return try await result.futureResult.get() }
        return try await result.futureResult.getAbandoningOnCancel()
    }
}
