# Integration suite patterns

Patterns for live-server / end-to-end integration tests with Swift Testing: cross-suite serialization, trait propagation on nested enums, SwiftPM filter semantics, async teardown, and credential gating.


## Serializing across suites (not just within)

`@Suite(.serialized)` only serializes tests **within** a single suite. Different suites in different files can still run in parallel against each other, even when both are marked `.serialized`.

To enforce serial execution across a whole integration test target, nest every child suite under a single parent suite and apply `.serialized` + `.enabled(if:)` to the parent. Traits propagate recursively to nested types.

```swift
@Suite(.serialized, .enabled(if: LiveServerFixture.isAvailable))
enum IntegrationTests {
    @Suite enum ProtocolLayer {}
    @Suite enum APILayer {}
    @Suite enum UILayer {}
}
```


## `@Suite` annotation on intermediate nested enums

Intermediate enums used purely for namespacing (e.g. `ProtocolLayer`, `APILayer`) must carry `@Suite` for Swift Testing to discover them and propagate parent traits correctly. Without `@Suite`, leaf test types under the enum may be discovered as standalone suites outside the parent's scope — losing serialization and condition traits.


## Extension pattern for nesting suites across files

Put the parent enum and layer enums in a central harness file. Individual test files then use `extension` to attach leaf suites:

```swift
// Tests/CheckoutTests.swift
extension IntegrationTests.APILayer {
    @Suite struct CheckoutTests {
        @Test func placesOrder() async throws { ... }
    }
}
```

This preserves the parent suite's trait propagation while letting each test live in its own file.


## `swift test --filter` is regex-only — no `tag:` syntax

SwiftPM's `swift test --filter` matches a regex against test specifier names (`<target>.<suite>/<test>`). It does **not** support `tag:` syntax. Tag-based filtering (`--filter "tag:foo"`) is an Xcode Test Plan feature, not available via the `swift test` CLI.

For layer-based filtering with `swift test`, use nested suite names that the regex can match:

```bash
swift test --filter IntegrationTests.APILayer
```


## Async teardown: scoped closure, not `defer { Task { ... } }`

`defer { Task { await tearDown() } }` is fire-and-forget — Swift Testing does not await detached tasks, so teardown may not finish before the next test starts. Serial tests can then race against stale state.

Use a scoped closure helper that awaits teardown explicitly in both the success and error paths:

```swift
static func withHarness(
    body: (TestHarness) async throws -> Void
) async throws {
    let harness = try await setUp()
    // `defer` cannot call async functions; use explicit try/catch.
    do {
        try await body(harness)
    } catch {
        await harness.tearDown()
        throw error
    }
    await harness.tearDown()
}
```

Make `tearDown()` non-throwing (swallow and log internally) so the original test error is always propagated rather than replaced by a cleanup error.


## Credential gating: `.enabled(if:)` with computed properties

Gate integration test suites that need external state (env vars, network, seeded accounts) with `.enabled(if: ...)` so they skip cleanly when the prerequisites are missing.

Expose gate properties as `static var` (computed) rather than `static let`, so a missing env var produces a clean skip at the suite gate rather than crashing the whole test runner via `preconditionFailure` during static initialization.

```swift
enum LiveServerFixture {
    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["LIVE_SERVER_URL"] != nil
    }
}
```
