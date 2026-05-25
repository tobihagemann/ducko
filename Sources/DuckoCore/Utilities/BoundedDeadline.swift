import Foundation

/// Runs `work`, returning when it finishes or `deadline` elapses — whichever comes first. On timeout the
/// in-flight `work` task is cancelled (cooperatively) and abandoned, so a stuck operation can't hold the
/// caller forever. Safe at process exit; callers that must observe `work`'s completion must not rely on it
/// past the deadline.
func runBounded(within deadline: Duration, _ work: @escaping @Sendable () async -> Void) async {
    let workTask = Task { await work() }
    let timeout = Task<Void, Never> {
        try? await Task.sleep(for: deadline)
    }
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    Task {
        _ = await workTask.value
        continuation.yield()
        continuation.finish()
    }
    Task {
        _ = await timeout.value
        continuation.yield()
        continuation.finish()
    }
    for await _ in stream {
        break
    }
    timeout.cancel()
    workTask.cancel()
}
