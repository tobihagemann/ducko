import DuckoTestSupport
import Testing

/// Polls `predicate` on the main actor until it holds, failing the test when `boundedOutcome`'s deadline passes first.
@MainActor
func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let result = try await boundedOutcome { @MainActor in
        while !predicate() {
            try Task.checkCancellation(); await Task.yield()
        }
    }
    try #require(result != nil)
    try result?.get()
}
