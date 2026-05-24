import ApplicationServices
import Testing

/// Pins the press-tentative-then-pick-classifies policy in
/// `AppAccessor.classifyContextMenuPressPick`, plus the `@autoclosure`
/// laziness contract that suppresses the pick AX dispatch on a successful
/// press. Top-level `enum` to opt out of the parent suite's `.enabled(if:)`
/// credentials trait.
enum ContextMenuPressPickTests {
    struct Routing {
        private let identifier = "context-menu/menu-item[Edit]"

        @Test func `press success skips the pick fallback`() {
            let result = AppAccessor.classifyContextMenuPressPick(
                press: .success,
                pick: .success,
                identifier: identifier
            )
            #expect(result == nil)
        }

        @Test func `press success does not evaluate the pick autoclosure`() {
            // Pins @autoclosure laziness: a successful press must not dispatch pick.
            let probe = PickProbe()
            let result = AppAccessor.classifyContextMenuPressPick(
                press: .success,
                pick: probe.dispatchAndReturn(.cannotComplete),
                identifier: identifier
            )
            #expect(result == nil)
            #expect(probe.dispatchCount == 0)
        }

        @Test func `press failure DOES evaluate the pick autoclosure exactly once`() {
            let probe = PickProbe()
            _ = AppAccessor.classifyContextMenuPressPick(
                press: .cannotComplete,
                pick: probe.dispatchAndReturn(.success),
                identifier: identifier
            )
            #expect(probe.dispatchCount == 1)
        }

        @Test func `press apiDisabled is fatal without consulting pick`() {
            // pick: .success is a decoy; expecting axTrustMissing proves it was bypassed.
            let result = AppAccessor.classifyContextMenuPressPick(
                press: .apiDisabled,
                pick: .success,
                identifier: identifier
            )
            #expect(result == .axTrustMissing)
        }

        @Test func `press cannotComplete falls through to pick success`() {
            let result = AppAccessor.classifyContextMenuPressPick(
                press: .cannotComplete,
                pick: .success,
                identifier: identifier
            )
            #expect(result == nil)
        }

        @Test func `press failure with pick apiDisabled surfaces axTrustMissing`() {
            let result = AppAccessor.classifyContextMenuPressPick(
                press: .cannotComplete,
                pick: .apiDisabled,
                identifier: identifier
            )
            #expect(result == .axTrustMissing)
        }

        @Test func `press failure with pick invalidUIElement surfaces elementNotFound`() {
            let result = AppAccessor.classifyContextMenuPressPick(
                press: .cannotComplete,
                pick: .invalidUIElement,
                identifier: identifier
            )
            #expect(result == .elementNotFound(identifier: identifier))
        }

        @Test func `press failure with pick cannotComplete surfaces axActionFailed`() {
            let result = AppAccessor.classifyContextMenuPressPick(
                press: .cannotComplete,
                pick: .cannotComplete,
                identifier: identifier
            )
            #expect(
                result == .axActionFailed(
                    identifier: identifier,
                    action: kAXPickAction,
                    axError: AXError.cannotComplete.rawValue
                )
            )
        }
    }
}

/// Reference type so `dispatchCount` is observable from the test after the
/// `@autoclosure` runs.
private final class PickProbe {
    private(set) var dispatchCount = 0

    func dispatchAndReturn(_ result: AXError) -> AXError {
        dispatchCount += 1
        return result
    }
}
