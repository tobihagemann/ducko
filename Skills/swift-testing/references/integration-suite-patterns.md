# Integration suite patterns

Patterns for live-server / end-to-end integration tests with Swift Testing: cross-suite serialization, trait propagation on nested enums, SwiftPM filter semantics, async teardown, and credential gating.


## Serializing across suites (not just within)

`@Suite(.serialized)` only serializes tests **within** a single suite. Different suites in different files can still run in parallel against each other, even when both are marked `.serialized`.

To enforce serial execution across a whole integration test target, nest every child suite under a single parent suite and apply `.serialized` + `.enabled(if:)` to the parent. Traits propagate recursively to nested types.

```swift
@Suite(.serialized, .enabled(if: LiveServerFixture.isAvailable))
enum IntegrationTests {
    enum ProtocolLayer {}
    enum APILayer {}
    enum UILayer {}
}
```


## `@Suite` annotation on intermediate nested enums

Bare `@Suite` (no arguments) on intermediate namespacing enums is **not** required in modern Swift Testing. Traits attached to a parent `@Suite` propagate through plain nested enums to leaf types via lexical nesting. Verified empirically: `.serialized` and `.enabled(if:)` on a root suite still govern leaf test types that live inside plain `enum Layer {}` namespaces.

SwiftFormat's `redundantSwiftTestingSuite` rule also strips bare `@Suite` — attempting to keep it on intermediate enums will be reverted by the formatter. Only attach `@Suite(arg)` when you need to add a specific trait (e.g., `@Suite(.serialized)`) to that exact type.

```swift
@Suite(.serialized, .enabled(if: LiveServerFixture.isAvailable))
enum IntegrationTests {
    enum ProtocolLayer {}
    enum APILayer {}
    enum UILayer {}
}

extension IntegrationTests.ProtocolLayer {
    struct MessagingTests {
        @Test func sendReceive() async throws { ... }
    }
}
```


## Extension pattern for nesting suites across files

Put the parent enum and layer enums in a central harness file. Individual test files then use `extension` to attach leaf suites:

```swift
// Tests/CheckoutTests.swift
extension IntegrationTests.APILayer {
    struct CheckoutTests {
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


## `Issue.record` + `return` silently passes scoped-closure tests

Inside a `withHarness { ... }` or similar scoped closure that returns `Void`, `Issue.record("..."); return` records a non-fatal failure but exits the closure normally — the test passes green. This is especially dangerous in mid-test extraction patterns:

```swift
// BAD: test passes green even though the assertion failed
let event = try await account.waitForEvent { ... }
if case let .messageReceived(m) = event {
    #expect(m.body == expected)
} else {
    Issue.record("Expected .messageReceived")  // non-fatal
    return  // exits closure normally — test passes!
}
```

Use `guard case let ... else { throw }` to fail hard:

```swift
// GOOD: thrown error propagates through the scoped closure and fails the test
guard case let .messageReceived(m) = event else {
    throw SomeTestError("Expected .messageReceived, got \(event)")
}
#expect(m.body == expected)
```

`Issue.record` is appropriate only for terminal assertions where no subsequent code depends on the result. For precondition checks or value extraction, always throw.


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
