import ApplicationServices
import Testing

/// Pins the retriable-vs-fatal AX-error classification in
/// `AppAccessor.mapPerformError`. Without this pure seam, a regression that
/// flips the retry policy would only surface as live UI test flake. Top-level
/// `enum` to opt out of the parent suite's `.enabled(if:)` credentials trait.
enum PerformErrorMappingTests {
    struct Routing {
        private let identifier = "chat-bubble-bob@example.com"
        private let action = "AXPress"

        @Test func `success maps to nil so the caller returns without throwing`() {
            #expect(AppAccessor.mapPerformError(.success, identifier: identifier, action: action) == nil)
        }

        @Test func `apiDisabled maps to axTrustMissing`() {
            #expect(
                AppAccessor.mapPerformError(.apiDisabled, identifier: identifier, action: action)
                    == .axTrustMissing
            )
        }

        /// Pins the load-bearing invariant: a stale handle between
        /// `resolveElement` and `AXUIElementPerformAction` must surface as
        /// `elementNotFound` so `retryOnStaleElement` re-walks from the
        /// application root. Flipping this to `axActionFailed` would silently
        /// break the stale-action-between-resolve-and-act recovery path.
        @Test func `invalidUIElement maps to retriable elementNotFound`() {
            #expect(
                AppAccessor.mapPerformError(.invalidUIElement, identifier: identifier, action: action)
                    == .elementNotFound(identifier: identifier)
            )
        }

        @Test func `cannotComplete maps to non-retriable axActionFailed`() {
            #expect(
                AppAccessor.mapPerformError(.cannotComplete, identifier: identifier, action: action)
                    == .axActionFailed(
                        identifier: identifier,
                        action: action,
                        axError: AXError.cannotComplete.rawValue
                    )
            )
        }

        @Test func `actionUnsupported maps to non-retriable axActionFailed`() {
            #expect(
                AppAccessor.mapPerformError(.actionUnsupported, identifier: identifier, action: action)
                    == .axActionFailed(
                        identifier: identifier,
                        action: action,
                        axError: AXError.actionUnsupported.rawValue
                    )
            )
        }

        @Test func `failure maps to non-retriable axActionFailed`() {
            #expect(
                AppAccessor.mapPerformError(.failure, identifier: identifier, action: action)
                    == .axActionFailed(
                        identifier: identifier,
                        action: action,
                        axError: AXError.failure.rawValue
                    )
            )
        }
    }
}
