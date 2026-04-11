# Actors

Data isolation and thread-safe state management in Swift. Actors protect mutable state by ensuring only one task accesses it at a time.

## Reentrancy — the #1 concurrency bug

**Important:** This is the most common concurrency bug LLMs produce. After every `await` inside an actor, all assumptions about the actor's state are invalidated because other calls may have run in the meantime.

```swift
// Bug: After the await, items[url] may already have been set by another caller.
// Duplicate work, and the force unwrap crashes if another caller removed the key
// between assignment and return.
actor VideoCache {
    var items: [URL: Video] = [:]

    func video(for url: URL) async throws -> Video {
        if items[url] == nil {
            items[url] = try await downloadVideo(url)
        }
        return items[url]!
    }
}
```

Fix: capture the result in a local, then assign. **Never assume state is unchanged after `await`.**

```swift
actor VideoCache {
    var items: [URL: Video] = [:]

    func video(for url: URL) async throws -> Video {
        if let cached = items[url] { return cached }
        let video = try await downloadVideo(url)
        items[url] = video
        return video
    }
}
```

To prevent two callers both downloading the same URL, store in-flight tasks:

```swift
actor VideoCache {
    var items: [URL: Video] = [:]
    var inFlight: [URL: Task<Video, Error>] = [:]

    func video(for url: URL) async throws -> Video {
        if let cached = items[url] { return cached }
        if let task = inFlight[url] { return try await task.value }

        let task = Task { try await downloadVideo(url) }
        inFlight[url] = task

        do {
            let video = try await task.value
            items[url] = video
            inFlight[url] = nil
            return video
        } catch {
            inFlight[url] = nil
            throw error
        }
    }
}
```

**Rule of thumb:** complete actor work before suspending wherever possible.

```swift
func deposit(amount: Double) async {
    balance += amount
    print("Balance: \(balance)") // Before suspension

    await logActivity("Deposited \(amount)")
}
```


## Actor basics

Actors are reference types with automatic synchronization — only one task accesses mutable state at a time (serialized access).

```swift
actor BankAccount {
    var balance: Int = 0

    func deposit(_ amount: Int) {
        balance += amount
    }
}

let account = BankAccount()
account.balance += 1      // ❌ Error: can't mutate from outside
await account.deposit(1)  // ✅ Must use actor's methods
print(await account.balance)  // Reads must await too
```

### Actors vs classes

- **Reference types** (copies share the same instance).
- **No inheritance** (except `NSObject` for Objective-C interop).
- **Automatic isolation** — no manual locks.
- **Implicit Sendable** conformance.


## Global actors

Shared isolation domain across types, functions, and properties.

### `@MainActor`

```swift
@MainActor
final class ViewModel {
    var items: [Item] = []
}

@MainActor
func updateUI() { }
```

Replace `DispatchQueue.main.async { ... }` with `@MainActor` annotations or `await MainActor.run { ... }` calls.

### Custom global actors

```swift
@globalActor
actor ImageProcessing {
    static let shared = ImageProcessing()
    private init() {}
}

@ImageProcessing
final class ImageCache {
    var images: [URL: Data] = [:]
}
```

**Use private init** to prevent creating multiple executors.

### Global actor inference rules

`@MainActor` propagates in these cases — don't redundantly annotate:

- A subclass of a `@MainActor` class is also `@MainActor`.
- Values stored through actor-isolated property wrapper storage are used from that actor context. (This includes older built-in property wrappers such as `@StateObject`.)
- Conforming to a `@MainActor` protocol infers `@MainActor` on the entire conforming type, including members unrelated to the protocol. SwiftUI's `View` is a `@MainActor` protocol.
- Extensions of a `@MainActor` type inherit that isolation.

`@MainActor` does **not** propagate to:

- Closures passed to non-isolated functions (unless the parameter is explicitly `@MainActor`).


## Protecting global and static state

Global and static mutable variables need an explicit plan for isolation:

- `@MainActor` when the symbol belongs to main-actor code and callers should keep synchronous access there (especially anything that interacts with UI).
- `@unchecked Sendable` when safety already comes from locks, queues, or another manual scheme the compiler cannot prove. **This requires a high standard of coding to get right — check carefully.**
- If neither is true, the shared global likely still has an isolation problem.

```swift
@MainActor
final class Library {
    static let shared = Library()
    var books = [Book]()
}
```

With main-actor default isolation enabled for the target, this annotation may be implicit — check the setting.

**Note:** `@preconcurrency` can relax an older protocol boundary when isolated conformance is unavailable. Keep it as a fallback only if there is no alternative.


## Isolated vs nonisolated

### `isolated` parameters

Accept any actor instance and run on its executor, without the function being tied to a specific actor:

```swift
struct Charger {
    static func charge(
        amount: Double,
        from account: isolated BankAccount
    ) async throws -> Double {
        // No `await` needed — already isolated to `account`
        try account.withdraw(amount: amount)
        return account.balance
    }
}

func updateUI(on actor: isolated MainActor) {
    // Runs on the main actor
}
```

Useful for reducing suspension points and for code that needs to work with the caller's isolation context.

### Isolated closures

```swift
actor Database {
    func transaction<T>(
        _ operation: @Sendable (_ db: isolated Database) throws -> T
    ) throws -> T {
        beginTransaction()
        defer { commitTransaction() }
        return try operation(self)
    }
}

// Usage: multiple operations, one await
try await database.transaction { db in
    db.insert(item1)
    db.insert(item2)
}
```

### `nonisolated`

Opt out of isolation for immutable data or protocol conformance:

```swift
actor BankAccount {
    let accountHolder: String

    nonisolated var details: String {
        "Account: \(accountHolder)"
    }
}

extension BankAccount: CustomStringConvertible {
    nonisolated var description: String {
        "Account: \(accountHolder)"
    }
}
```

Use `nonisolated` sparingly — only for truly immutable data.


## Isolated deinit (Swift 6.2+)

Clean up actor state on deallocation:

```swift
actor FileDownloader {
    var downloadTask: Task<Void, Error>?

    isolated deinit {
        downloadTask?.cancel()
    }
}
```

Requires iOS 18.4+ / macOS 15.4+. For more on this feature see `new-features.md`.


## Global actor isolated conformance (Swift 6.2+)

Protocol conformance that respects actor isolation:

```swift
@MainActor
final class PersonViewModel {
    let id: UUID
    var name: String
}

extension PersonViewModel: @MainActor Equatable {
    static func == (lhs: PersonViewModel, rhs: PersonViewModel) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}
```

Enable with the `InferIsolatedConformances` upcoming feature.


## `#isolation` macro

Inherit the caller's isolation for generic code:

```swift
extension Collection where Element: Sendable {
    func sequentialMap<Result: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        transform: (Element) async -> Result
    ) async -> [Result] {
        var results: [Result] = []
        for element in self {
            results.append(await transform(element))
        }
        return results
    }
}
```

### Task closures and isolation inheritance

When spawning unstructured `Task` closures that need to work with non-Sendable types, capture the isolation parameter to inherit the caller's isolation context:

```swift
// Problem: Task closures are @Sendable and cannot capture non-Sendable types
func process(delegate: NonSendableDelegate) {
    Task {
        delegate.doWork() // ❌ capturing non-Sendable type
    }
}

// Solution: use #isolation and force capture inside the Task
func process(
    delegate: NonSendableDelegate,
    isolation: isolated (any Actor)? = #isolation
) {
    Task {
        _ = isolation  // Forces capture, Task inherits caller's isolation
        delegate.doWork()  // ✅ safe on caller's actor
    }
}
```

Per [SE-0420](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0420-inheritance-of-actor-isolation.md), `Task` closures only inherit isolation when a non-optional binding of an isolated parameter is captured. `_ = isolation` forces this capture.


## Custom actor executors

Advanced: control how an actor schedules work.

```swift
final class DispatchQueueExecutor: SerialExecutor {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async {
            unownedJob.runSynchronously(on: executor)
        }
    }
}

actor LoggingActor {
    private let executor: DispatchQueueExecutor

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    init(queue: DispatchQueue) {
        executor = DispatchQueueExecutor(queue: queue)
    }
}
```

Use cases: legacy DispatchQueue integration, C++ interop, custom scheduling. The default executor is usually sufficient.


## Mutex — alternative to actors

Synchronous locking without async/await overhead (iOS 18+, macOS 15+):

```swift
import Synchronization

final class Counter {
    private let count = Mutex<Int>(0)

    var currentCount: Int {
        count.withLock { $0 }
    }

    func increment() {
        count.withLock { $0 += 1 }
    }
}
```

Works as a Sendable wrapper around non-Sendable types:

```swift
final class TouchesCapturer: Sendable {
    let path = Mutex<NSBezierPath>(NSBezierPath())

    func storeTouch(_ point: NSPoint) {
        path.withLock { path in path.move(to: point) }
    }
}
```

| Feature | Mutex | Actor |
|---------|-------|-------|
| Synchronous | ✅ | ❌ (requires await) |
| Async support | ❌ | ✅ |
| Thread blocking | ✅ | ❌ (cooperative) |
| Fine-grained locking | ✅ | ❌ (whole actor) |
| Legacy code integration | ✅ | ❌ |

Use **Mutex** when you need synchronous access, fine-grained locking, or legacy non-async API integration. Use an **Actor** when you can adopt async/await, need logical isolation, or are already in an async context.


## Assertions

Global actors have an `assertIsolated()` method that halts debug builds if the current task is not executing on the actor's serial executor:

```swift
func refresh() {
    MainActor.assertIsolated()
    // do your work here
}
```

**Important:** `assertIsolated()` only runs in debug builds (compiled out of release), so it has no shipping-performance impact.


## What a custom actor changes

A custom actor introduces a separate serialized access boundary:

- External callers must use `await`.
- Values crossing the boundary must satisfy `Sendable`.
- Reentrancy rules apply after every suspension point inside the actor.

Flag actor types whose API mostly forwards work or owns little mutable state. Don't encourage reaching for actors when simpler alternatives work equally well. Matt Massicotte has good material on this: <https://www.massicotte.org/actors/>.


## Decision tree

```
Need thread-safe mutable state?
├─ Async context?
│  ├─ Single instance? → Actor
│  ├─ Global/shared? → Global Actor (@MainActor, custom)
│  └─ UI-related? → @MainActor
│
└─ Synchronous context?
   ├─ Can refactor to async? → Actor
   ├─ Legacy code integration? → Mutex
   └─ Fine-grained locking? → Mutex
```


## Best practices

1. Prefer actors over manual locks for async code.
2. Use `@MainActor` for UI — view models, UI updates.
3. Minimize work in actors — keep critical sections short.
4. Watch for reentrancy — don't assume state unchanged after `await`.
5. Use `nonisolated` sparingly — only for truly immutable data.
6. Avoid `MainActor.assumeIsolated` — prefer explicit `@MainActor` or `await MainActor.run`.
7. Custom executors are rare — the default is usually best.
8. Consider `Mutex` for sync code where async overhead isn't needed.
9. Complete actor work before suspending where possible.
10. Use isolated parameters to reduce suspension points.
