import Foundation
import Logging

private let log = Logger(label: "im.ducko.integrationtests.timeout")

/// Runs `action` with a soft deadline: once `timeout` elapses the helper
/// logs a warning, but still waits for `action` to unwind via cooperative
/// cancellation before returning. Callers must use cancellation-aware work.
func runIntegrationCleanup(
    _ action: @escaping @Sendable () async -> Void,
    timeout: Duration,
    label: String
) async {
    let timedOut: Bool = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await action()
            return false
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return true
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    if timedOut {
        log.warning("\(label) cleanup action timed out after \(timeout)")
    }
}
