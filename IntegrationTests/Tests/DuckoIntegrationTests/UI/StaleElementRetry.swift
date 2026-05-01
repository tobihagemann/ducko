import Foundation

/// Re-runs `action` on transient `TestHarnessError.elementNotFound` failures.
/// The underlying `AXUIElement` reference returned by `resolveElement` is
/// invalidated when the SwiftUI view re-mounts (e.g. `ContactRow` re-renders
/// when a presence update lands), so a fresh walk from the application root
/// is required to pick up the new element. The action must re-call
/// `resolveElement` itself every attempt — passing a stale handle in does
/// not recover. Other `TestHarnessError` cases (`timeout`, `axTrustMissing`)
/// are not retried.
func retryOnStaleElement<T>(
    identifier: String,
    maxAttempts: Int = 3,
    backoff: Duration = .milliseconds(50),
    isolation: isolated (any Actor)? = #isolation,
    _ action: () async throws -> T
) async throws -> T {
    for attempt in 0 ..< maxAttempts {
        do {
            return try await action()
        } catch TestHarnessError.elementNotFound {
            if attempt < maxAttempts - 1 {
                try await Task.sleep(for: backoff)
            }
        }
    }
    throw TestHarnessError.elementNotFound(identifier: identifier)
}
