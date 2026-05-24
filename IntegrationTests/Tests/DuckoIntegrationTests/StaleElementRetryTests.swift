import Foundation
import Testing

/// Deterministic coverage for `retryOnStaleElement`. The live UI tests only
/// hit the retry/exhaustion branches when SwiftUI happens to re-mount during
/// a real run, so a regression in the retry policy (wrong error filter, lost
/// backoff, swallowed exhaustion) would slip past green CI.
///
/// Declared as a top-level `enum` so the suite does not inherit
/// `DuckoIntegrationTests`'s `.enabled(if: TestCredentials.isAvailable)`
/// trait — the helper has no live-server dependency and must run on any
/// developer or CI environment.
enum StaleElementRetryTests {
    struct Behaviour {
        @Test
        func `success on first attempt is returned without retry`() async throws {
            let attempts = AttemptCounter()

            let result = try await retryOnStaleElement(identifier: "fixture") {
                await attempts.bump()
                return 42
            }

            #expect(result == 42)
            #expect(await attempts.count == 1)
        }

        @Test
        func `success after one stale failure returns the second-attempt value`() async throws {
            let attempts = AttemptCounter()

            let result = try await retryOnStaleElement(identifier: "fixture") { () async throws -> Int in
                let attempt = await attempts.bump()
                if attempt == 1 {
                    throw TestHarnessError.elementNotFound(identifier: "fixture")
                }
                return 99
            }

            #expect(result == 99)
            #expect(await attempts.count == 2)
        }

        /// Boundary: action fails on attempts 1 and 2, succeeds on attempt 3.
        /// Pins the off-by-one — a regression shortening the loop bound to
        /// `0..<maxAttempts-1` would still pass the other tests but break this.
        @Test
        func `success on the final allowed attempt is returned`() async throws {
            let attempts = AttemptCounter()

            let result = try await retryOnStaleElement(identifier: "fixture", backoff: .milliseconds(1)) { () async throws -> Int in
                let attempt = await attempts.bump()
                if attempt < 3 {
                    throw TestHarnessError.elementNotFound(identifier: "fixture")
                }
                return 7
            }

            #expect(result == 7)
            #expect(await attempts.count == 3)
        }

        /// Pins that retry exhaustion rethrows the inner closure's identifier
        /// (e.g. `"picker/segment[General]"`), not the outer wrapper's, so a
        /// stable child-miss reports the qualified shape.
        @Test
        func `retry exhaustion rethrows the most recently caught inner identifier`() async throws {
            let attempts = AttemptCounter()

            await #expect(throws: TestHarnessError.elementNotFound(identifier: "picker/segment[General]")) {
                _ = try await retryOnStaleElement(identifier: "picker", backoff: .milliseconds(1)) { () async throws -> Int in
                    await attempts.bump()
                    throw TestHarnessError.elementNotFound(identifier: "picker/segment[General]")
                }
            }

            #expect(await attempts.count == 3)
        }

        /// Defensive: when `maxAttempts` is zero the action never runs, so
        /// no inner error is captured; the helper falls back to the
        /// wrapper-supplied `identifier`. Pins the only path that uses the
        /// outer identifier in the exhaustion message.
        @Test
        func `zero attempts falls back to the wrapper identifier`() async throws {
            await #expect(throws: TestHarnessError.elementNotFound(identifier: "outer")) {
                _ = try await retryOnStaleElement(identifier: "outer", maxAttempts: 0, backoff: .milliseconds(1)) { () async throws -> Int in
                    1
                }
            }
        }

        @Test
        func `non-stale errors propagate without retry`() async throws {
            let attempts = AttemptCounter()

            await #expect(throws: TestHarnessError.timeout) {
                _ = try await retryOnStaleElement(identifier: "fixture") { () async throws -> Int in
                    await attempts.bump()
                    throw TestHarnessError.timeout
                }
            }

            #expect(await attempts.count == 1)
        }
    }
}

private actor AttemptCounter {
    private(set) var count = 0

    @discardableResult
    func bump() -> Int {
        count += 1
        return count
    }
}
