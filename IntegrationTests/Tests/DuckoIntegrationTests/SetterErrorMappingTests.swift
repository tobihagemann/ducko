import ApplicationServices
import Testing

/// Pins the routing policy of `AppAccessor.mapSetterError`. The switch is
/// consumed inline from `type()` over a real `AXUIElement`, so this pure
/// seam is the only deterministic way to catch a regression that flipped
/// `.invalidUIElement` and the default arm (silently re-introducing the
/// stale-handle bug). Top-level `enum` to opt out of the parent suite's
/// `.enabled(if:)` credentials trait.
enum SetterErrorMappingTests {
    struct Routing {
        private let identifier = "message-field"

        @Test func `success maps to done`() {
            #expect(AppAccessor.mapSetterError(.success, identifier: identifier) == .done)
        }

        @Test func `apiDisabled maps to error(axTrustMissing)`() {
            #expect(
                AppAccessor.mapSetterError(.apiDisabled, identifier: identifier)
                    == .error(.axTrustMissing)
            )
        }

        @Test func `invalidUIElement maps to retriable error(elementNotFound)`() {
            #expect(
                AppAccessor.mapSetterError(.invalidUIElement, identifier: identifier)
                    == .error(.elementNotFound(identifier: identifier))
            )
        }

        @Test func `attributeUnsupported maps to needsFallback for SwiftUI TextField path`() {
            #expect(
                AppAccessor.mapSetterError(.attributeUnsupported, identifier: identifier)
                    == .needsFallback
            )
        }

        @Test func `failure maps to needsFallback for SwiftUI TextField path`() {
            #expect(
                AppAccessor.mapSetterError(.failure, identifier: identifier)
                    == .needsFallback
            )
        }

        @Test func `cannotComplete maps to needsFallback`() {
            #expect(
                AppAccessor.mapSetterError(.cannotComplete, identifier: identifier)
                    == .needsFallback
            )
        }
    }
}
