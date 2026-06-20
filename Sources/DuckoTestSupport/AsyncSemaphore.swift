/// Counting permit-based async semaphore used to gate test progress at a specific suspension point
/// inside the system under test. `signal` before any `wait` increments a permit so the next `wait`
/// returns immediately — signals are never dropped.
public actor AsyncSemaphore {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var permits = 0

    public init() {}

    public func signal() {
        if let next = pending.first {
            pending.removeFirst()
            next.resume()
        } else {
            permits += 1
        }
    }

    public func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
    }
}
