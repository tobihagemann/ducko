---
name: swift-concurrency
description: Expert guidance on Swift Concurrency correctness, modern API usage, and async/await pitfalls in Swift 6.2+. Use when developers mention async/await, actors, tasks, @MainActor, Sendable, isolation, Swift 6 migration, strict concurrency diagnostics, AsyncSequence/AsyncStream, async_without_await lint warnings, or data-race issues.
license: MIT
---

Review, write, and improve Swift Concurrency code for correctness, modern API usage, data-race safety, and adherence to project conventions. Report only genuine problems — do not nitpick or invent issues.


## First 60 seconds (triage template)

Before making recommendations, capture the minimum context you need:

- **Swift language mode** (Swift 5.x vs Swift 6) and SwiftPM tools version.
- **Default actor isolation** — is the module default `@MainActor` or `nonisolated`? (Swift 6.2 "approachable concurrency".)
- **Strict concurrency level** — minimal / targeted / complete.
- **Upcoming features** enabled, especially `NonisolatedNonsendingByDefault` and `InferIsolatedConformances`.
- **Current actor context** of the offending symbol — `@MainActor`, custom actor, instance isolation, or nonisolated.
- **Is the code UI-bound** or intended to run off the main actor?

If any of these are unknown, ask the developer to confirm before giving migration-sensitive guidance.


## Project Settings Intake

Before diving in, inspect the build settings:

- **SwiftPM**: check `Package.swift` for
  - `// swift-tools-version: ...`
  - `.defaultIsolation(MainActor.self)`
  - `.enableUpcomingFeature("NonisolatedNonsendingByDefault")`
  - `.enableExperimentalFeature("StrictConcurrency=targeted")` (or similar)
- **Xcode projects**: search `project.pbxproj` for
  - `SWIFT_DEFAULT_ACTOR_ISOLATION`
  - `SWIFT_STRICT_CONCURRENCY`
  - `SWIFT_UPCOMING_FEATURE_` (and/or `SWIFT_ENABLE_EXPERIMENTAL_FEATURES`)

```bash
rg "SWIFT_DEFAULT_ACTOR_ISOLATION|SWIFT_STRICT_CONCURRENCY|SWIFT_UPCOMING_FEATURE_" -n
```


## Review process

1. Scan for known-dangerous patterns using [references/hotspots.md](references/hotspots.md) to prioritize what to inspect.
2. Check Swift 6.2 concurrency behavior using [references/new-features.md](references/new-features.md), [references/swift-6-2-concurrency.md](references/swift-6-2-concurrency.md), and (if opted in) [references/approachable-concurrency.md](references/approachable-concurrency.md).
3. Validate actor usage, reentrancy, and isolation correctness using [references/actors.md](references/actors.md).
4. Validate Sendable conformance using [references/sendable.md](references/sendable.md).
5. Check threading, isolation domains, and nonisolated patterns using [references/threading.md](references/threading.md).
6. Ensure structured concurrency is preferred over unstructured where appropriate using [references/structured.md](references/structured.md) and [references/tasks.md](references/tasks.md).
7. Check unstructured task usage for correctness using [references/unstructured.md](references/unstructured.md).
8. Verify cancellation is handled correctly using [references/cancellation.md](references/cancellation.md).
9. Validate async stream, continuation, and AsyncSequence usage using [references/async-streams.md](references/async-streams.md) and [references/async-sequences.md](references/async-sequences.md).
10. For complex stream composition, check [references/async-algorithms.md](references/async-algorithms.md).
11. Check `async`/`await` basics and common `async let` / `withTaskGroup` patterns using [references/async-await-basics.md](references/async-await-basics.md).
12. Check memory safety (retain cycles in tasks) using [references/memory-management.md](references/memory-management.md).
13. Check bridging code between sync and async worlds using [references/bridging.md](references/bridging.md).
14. Review any legacy concurrency migrations using [references/interop.md](references/interop.md) and [references/migration.md](references/migration.md).
15. Review Core Data–specific concurrency using [references/core-data.md](references/core-data.md).
16. Cross-check against common failure modes using [references/bug-patterns.md](references/bug-patterns.md).
17. If the project has strict-concurrency errors or SwiftLint warnings, map diagnostics to fixes using [references/diagnostics.md](references/diagnostics.md) and [references/linting.md](references/linting.md).
18. For performance tuning, see [references/performance.md](references/performance.md).
19. For SwiftUI-specific concurrency, see [references/swiftui-concurrency-tour-wwdc.md](references/swiftui-concurrency-tour-wwdc.md).
20. If reviewing tests, check async test patterns using [references/testing.md](references/testing.md).
21. For terminology, see [references/glossary.md](references/glossary.md).

If doing a partial review, load only the relevant reference files.


## Core Instructions

- Target Swift 6.2 or later with strict concurrency checking.
- If code spans multiple targets or packages, compare their concurrency build settings before assuming behavior should match.
- Prefer structured concurrency (task groups) over unstructured (`Task {}`).
- Prefer Swift concurrency over Grand Central Dispatch for new code. GCD is still acceptable in low-level code, framework interop, or performance-critical synchronous work where queues and locks are the right tool — don't flag these as errors.
- If an API offers both `async`/`await` and closure-based variants, always prefer `async`/`await`.
- Do not introduce third-party concurrency frameworks without asking first.
- Do not suggest `@unchecked Sendable` to fix compiler errors. It silences the diagnostic without fixing the underlying race. Prefer actors, value types, or `sending` parameters instead. The only legitimate use is for types with internal locking that are provably thread-safe.
- Do not recommend `@MainActor` as a blanket fix. Justify why main-actor isolation is correct for the code.
- Use `Task.detached` only with a clear, documented reason.
- If recommending `@preconcurrency`, `@unchecked Sendable`, or `nonisolated(unsafe)`, require a documented safety invariant and a follow-up ticket to remove or migrate it.
- For migration work, optimize for minimal blast radius — small, reviewable changes plus verification steps.


## Triage-First Playbook

Common errors → next best move:

- **SwiftLint concurrency-related warnings** → use [references/linting.md](references/linting.md) for rule intent and preferred fixes. Never "fix" `async_without_await` by adding a dummy `await`; remove the unused `async` or suppress narrowly.
- **"Sending value of non-Sendable type ... risks causing data races"** → identify where the value crosses an isolation boundary, then check [references/sendable.md](references/sendable.md) and [references/threading.md](references/threading.md) (especially Swift 6.2 behavior changes).
- **"Main actor-isolated ... cannot be used from a nonisolated context"** → decide if it truly belongs on `@MainActor`; then use [references/actors.md](references/actors.md) (global actors, `nonisolated`, isolated parameters) and [references/threading.md](references/threading.md).
- **"Class property 'current' is unavailable from asynchronous contexts"** (Thread APIs) → use [references/threading.md](references/threading.md) to stop thread-centric debugging and rely on isolation + Instruments.
- **XCTest async errors like "wait(...) is unavailable from asynchronous contexts"** → use [references/testing.md](references/testing.md) (`await fulfillment(of:)` and Swift Testing patterns).
- **Core Data concurrency warnings/errors** → use [references/core-data.md](references/core-data.md) (DAO / `NSManagedObjectID`, default isolation conflicts).
- **"Actor cache duplicates downloads / force-unwrap crash"** → classic reentrancy bug; see [references/actors.md](references/actors.md).


## When to use each concurrency tool

**`async`/`await`** — making existing synchronous code asynchronous:

```swift
func fetchUser() async throws -> User {
    try await networkClient.get("/user")
}
```

**`async let`** — fixed number of parallel operations known at compile time:

```swift
async let user = fetchUser()
async let posts = fetchPosts()
let profile = try await (user, posts)
```

**`Task`** — fire-and-forget work, bridging sync to async contexts:

```swift
Task {
    await updateUI()
}
```

**`withTaskGroup` / `withThrowingTaskGroup`** — dynamic parallel operations:

```swift
try await withThrowingTaskGroup(of: Data.self) { group in
    for url in urls {
        group.addTask { try await fetch(url) }
    }
    for try await result in group {
        process(result)
    }
}
```

**`actor`** — protecting mutable state from data races:

```swift
actor DataCache {
    private var cache: [String: Data] = [:]
    func get(_ key: String) -> Data? { cache[key] }
}
```

**`@MainActor`** — UI-related classes and view models:

```swift
@MainActor
final class ViewModel: ObservableObject {
    @Published var data: String = ""
}
```


## Swift 6 migration quick guide

Key behavior changes in Swift 6:

- Strict concurrency checking enabled by default.
- Complete data-race safety at compile time.
- `Sendable` requirements enforced at boundaries.
- Isolation checking for all async boundaries.

For full migration strategy, see [references/migration.md](references/migration.md). For Swift 6.2 specifics (default actor isolation, isolated conformances, `@concurrent`, `Task.immediate`, task naming), see [references/swift-6-2-concurrency.md](references/swift-6-2-concurrency.md). For Approachable Concurrency mode, see [references/approachable-concurrency.md](references/approachable-concurrency.md).


## Output Format

Organize findings by file. For each issue:

1. State the file and relevant line(s).
2. Name the rule being violated.
3. Show a brief before/after code fix.

Skip files with no issues. End with a prioritized summary of the most impactful changes to make first.

Example output:

### DataLoader.swift

**Line 18: Actor reentrancy – state may have changed across the `await`.**

```swift
// Before
actor Cache {
    var items: [String: Data] = [:]

    func fetch(_ key: String) async throws -> Data {
        if items[key] == nil {
            items[key] = try await download(key)
        }
        return items[key]!
    }
}

// After
actor Cache {
    var items: [String: Data] = [:]

    func fetch(_ key: String) async throws -> Data {
        if let existing = items[key] { return existing }
        let data = try await download(key)
        items[key] = data
        return data
    }
}
```

**Line 34: Use `withTaskGroup` instead of creating tasks in a loop.**

```swift
// Before
for url in urls {
    Task { try await fetch(url) }
}

// After
try await withThrowingTaskGroup(of: Data.self) { group in
    for url in urls {
        group.addTask { try await fetch(url) }
    }

    for try await result in group {
        process(result)
    }
}
```

### Summary

1. **Correctness (high):** Actor reentrancy bug on line 18 may cause duplicate downloads and a force-unwrap crash.
2. **Structure (medium):** Unstructured tasks in loop on line 34 lose cancellation propagation.

End of example.


## References

### Foundations

- [references/async-await-basics.md](references/async-await-basics.md) — `async`/`await` syntax, execution order, `async let`, URLSession patterns.
- [references/glossary.md](references/glossary.md) — quick definitions of core concurrency terms.
- [references/hotspots.md](references/hotspots.md) — grep targets for code review: known-dangerous patterns and what to check for each.

### Swift 6.2 specifics

- [references/new-features.md](references/new-features.md) — Swift 6.2 changes: default actor isolation, isolated conformances, caller-actor async behavior, `@concurrent`, `Task.immediate`, task naming, priority escalation.
- [references/swift-6-2-concurrency.md](references/swift-6-2-concurrency.md) — Dimillian's Swift 6.2 feature tour and patterns.
- [references/approachable-concurrency.md](references/approachable-concurrency.md) — guidance when the project is opted into approachable concurrency mode.

### Actors & isolation

- [references/actors.md](references/actors.md) — actor reentrancy, shared-state annotations, global actor inference, isolated parameters, `#isolation`, Mutex comparison.
- [references/threading.md](references/threading.md) — thread/task relationship, suspension points, isolation domains, nonisolated, default isolation behavior.
- [references/sendable.md](references/sendable.md) — Sendable conformance, value vs reference types, `@unchecked` pitfalls, region isolation.

### Tasks & structured concurrency

- [references/tasks.md](references/tasks.md) — Task lifecycle, priorities, task groups, structured vs unstructured.
- [references/structured.md](references/structured.md) — task groups over loops, discarding task groups, concurrency limits.
- [references/unstructured.md](references/unstructured.md) — `Task` vs `Task.detached`, when `Task {}` is a code smell.
- [references/cancellation.md](references/cancellation.md) — cancellation propagation, cooperative checking, broken cancellation patterns.

### Streams & sequences

- [references/async-streams.md](references/async-streams.md) — AsyncStream factory, continuation lifecycle, back-pressure.
- [references/async-sequences.md](references/async-sequences.md) — AsyncSequence patterns, when to use vs regular async methods.
- [references/async-algorithms.md](references/async-algorithms.md) — composing streams with swift-async-algorithms.

### Bridging & interop

- [references/bridging.md](references/bridging.md) — checked continuations, wrapping legacy APIs, `@unchecked Sendable`.
- [references/interop.md](references/interop.md) — migrating from GCD, `Mutex`/locks, completion handlers, delegates, Combine.
- [references/core-data.md](references/core-data.md) — NSManagedObject sendability, custom executors, isolation conflicts.
- [references/memory-management.md](references/memory-management.md) — retain cycles in tasks, memory safety patterns.

### Diagnostics & bug patterns

- [references/bug-patterns.md](references/bug-patterns.md) — common concurrency failure modes and their fixes.
- [references/diagnostics.md](references/diagnostics.md) — strict-concurrency compiler errors, protocol conformance fixes, likely remedies.
- [references/linting.md](references/linting.md) — SwiftLint concurrency rules (`async_without_await`, Sendable/actor isolation) and preferred fixes.

### Performance, SwiftUI, and migration

- [references/performance.md](references/performance.md) — profiling with Instruments, reducing suspension points, execution strategies.
- [references/swiftui-concurrency-tour-wwdc.md](references/swiftui-concurrency-tour-wwdc.md) — SwiftUI-specific concurrency guidance.
- [references/migration.md](references/migration.md) — Swift 6 migration strategy, closure-to-async conversion, `@preconcurrency`, FRP migration.

### Testing

- [references/testing.md](references/testing.md) — async test strategy with Swift Testing, `.serialized` trait gotchas, race detection with TSan, `withMainSerialExecutor`, avoiding timing-based tests.
