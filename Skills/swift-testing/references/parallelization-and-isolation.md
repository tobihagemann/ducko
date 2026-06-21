# Parallelization and Isolation

## When to use this reference

Use this file when tests are flaky in CI, have hidden ordering dependencies, or need to scale execution speed safely.

## Default execution model

- Swift Testing runs test functions in parallel by default.
- Execution order is randomized to expose hidden test dependencies.
- Parallelization applies to synchronous and asynchronous tests.

## Example: hidden dependency exposed by parallel execution

```swift
import Testing

enum SharedStore {
 static var counter = 0
}

@Test func incrementsCounter() {
 SharedStore.counter += 1
 #expect(SharedStore.counter >= 1)
}

@Test func expectsFreshCounter() {
 // Flaky if tests run in parallel or random order.
 #expect(SharedStore.counter == 0)
}
```

## Why this matters

- Faster CI feedback and shorter local iteration loops.
- Better detection of shared-state coupling and flaky behavior.
- More realistic stress on concurrency-sensitive code paths.

## Isolation strategy first

- Make tests independent by default.
- Avoid shared mutable globals and singleton mutation across tests.
- Isolate state per test invocation (fresh suite instance helps).
- Prefer deterministic test data setup over implicit ordering assumptions.

### Better pattern: isolate per test

```swift
import Testing

struct CounterStore {
 var counter = 0
 mutating func increment() { counter += 1 }
}

@Test func isolatedCounter() {
 var store = CounterStore()
 store.increment()
 #expect(store.counter == 1)
}
```

## `.serialized` as a targeted tool

- `.serialized` is **scope-dependent** (see `async-tests.md`): on a **suite** (`@Suite(.serialized)`) it serializes the suite's contained test functions (parameterized or not) and sub-suites relative to each other; on a **parameterized `@Test`** it serializes that test's argument cases; on a **bare non-parameterized function** it has no effect.
- Apply it to a suite when that suite's tests must not run concurrently with each other (e.g. they share mutable state).
- Use it as a transitional safety measure during migration from serial XCTest suites.
- Refactor toward parallel-safe tests before normalizing serialization everywhere.
- Serialized suites can still run alongside unrelated suites in parallel — `.serialized` only governs the scope it is attached to, not the whole run.
- `@Suite(.serialized)` *will* stop two non-parameterized tests in that suite from running concurrently — but isolating their shared state is still the more durable fix (it survives the tests being split across suites or run with `--no-parallel` toggled).

### Transitional serialization example

```swift
import Testing

// On a suite, `.serialized` serializes ALL contained tests relative to each
// other — these two ordinary tests will not run concurrently, and any
// parameterized test's cases are serialized too.
@Suite(.serialized)
struct LegacyDatabaseTests {
 @Test func migrateUp() { #expect(apply(.up)) }
 @Test func migrateDown() { #expect(apply(.down)) }
}
```

## Shared resource scenarios

- If tests hit a shared DB/file/service, choose one:
  - isolate backing state per test
  - use in-memory substitutes
  - create separate serial test plan for integration path
- Prefer architecture that supports both fast in-memory tests and selective real integration tests.

### Shared on-disk state across cases of the same suite

When every test in a suite mutates the same well-known on-disk file (e.g. a
file-backed credential store under `~/Library/Application Support/...`,
`/tmp` artifacts written under a fixed name, a single SQLite file the suite
seeds and tears down), default parallel execution lets one test's `delete()`
race another test's `save()`, producing intermittent `noSuchFile` errors.

The durable fix is to remove the shared fixed path, not to serialize: refactor
toward an injectable backend each test can point at its own temporary
directory, so the tests carry no shared on-disk state to race over. Pair that
with a leading `delete()` (or equivalent reset) at the top of each test so a
prior crash can't leak state into the next run.

```swift
@Test func roundTrip() throws {
    let store = CredentialStore(directory: makeTempDir())  // per-test isolation
    store.delete()       // reset in case a prior run leaked state
    try store.save(...)
    // ...
    store.delete()
}
```

`@Suite(.serialized)` *can* paper over this race — it stops the suite's tests
from running concurrently, so the shared-path `delete()`/`save()` no longer
interleave. But prefer isolating the backing state: serialization is a coarse,
suite-local guard that breaks the moment the tests are split across suites or
someone runs a single test in isolation, whereas per-test temp directories
carry no shared state to race over in the first place.

## Do / Don't

- Do fix shared-state coupling before adding broad serialization.
- Do use in-memory fakes for the fast path.
- Don't rely on execution order.
- Don't mutate singletons across tests without reset/isolation.
