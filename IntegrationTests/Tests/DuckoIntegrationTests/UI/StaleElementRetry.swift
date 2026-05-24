import Foundation

/// Re-runs `action` on transient `TestHarnessError.elementNotFound` failures.
/// The underlying `AXUIElement` reference returned by `resolveElement` is
/// invalidated when the SwiftUI view re-mounts (e.g. `ContactRow` re-renders
/// when a presence update lands), so a fresh walk from the application root
/// is required to pick up the new element. The action must re-call
/// `resolveElement` itself every attempt — passing a stale handle in does
/// not recover. Other `TestHarnessError` cases (`timeout`, `axTrustMissing`)
/// are not retried.
///
/// On exhaustion, rethrows the most recently caught `elementNotFound` rather
/// than re-wrapping the call site's `identifier` — this preserves qualified
/// inner identifiers (e.g. `"\(picker)/segment[\(title)]"`) thrown by
/// helpers that wrap their full body in retry, so a stable child-miss
/// reports the qualified diagnostic identifier instead of the outer
/// container's. The `identifier:` argument is the fallback used only when no
/// attempt landed (`maxAttempts == 0`, defensive only).
func retryOnStaleElement<T>(
    identifier: String,
    maxAttempts: Int = 3,
    backoff: Duration = .milliseconds(50),
    isolation: isolated (any Actor)? = #isolation,
    _ action: () async throws -> T
) async throws -> T {
    var lastError: TestHarnessError = .elementNotFound(identifier: identifier)
    for attempt in 0 ..< maxAttempts {
        do {
            return try await action()
        } catch let TestHarnessError.elementNotFound(innerID) {
            lastError = .elementNotFound(identifier: innerID)
            if attempt < maxAttempts - 1 {
                try await Task.sleep(for: backoff)
            }
        }
    }
    throw lastError
}
