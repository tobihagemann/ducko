# Cancellation

Cancellation in Swift concurrency is cooperative. Setting the cancelled flag does nothing unless the running code checks it.

## How cancellation propagates

- Cancelling a parent task cancels all its children (structured concurrency).
- Cancelling a task group cancels all child tasks in that group.
- `Task {}` and `Task.detached {}` are unstructured – they must be cancelled explicitly by storing and calling `.cancel()` on the task handle.
- SwiftUI's `.task()` modifier cancels its task automatically when the view disappears. This is the primary reason to prefer `.task()` over `onAppear()` or loose `Task {}` in views.


## Checking for cancellation

It’s important to use these inside long-running or looping async work, but only when it’s safe to actually exit:

- `try Task.checkCancellation()` – throws `CancellationError` if cancelled. Preferred in throwing contexts.
- `Task.isCancelled` – returns `Bool`. Use in non-throwing contexts or when you need cleanup before exiting.

```swift
func processAll(_ items: [Item]) async throws {
    for item in items {
        try Task.checkCancellation()
        try await process(item)
    }
}
```

Functions that call other async functions get implicit cancellation checks at each `await` suspension point – but only if the called function itself checks. CPU-bound loops with no `await` will never see cancellation unless you check explicitly.


## `withTaskCancellationHandler`

Bridges Swift cancellation to legacy APIs that have their own cancel mechanism. The `onCancel` closure fires immediately when cancellation is requested – even while the async body is suspended – and may run on any thread.

```swift
func fetchImage(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url)
    return try await withTaskCancellationHandler {
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    } onCancel: {
        // No direct handle to cancel here – URLSession.data(for:) already
        // checks for task cancellation internally. This pattern is most
        // useful when wrapping APIs that return a cancellable handle.
    }
}
```

A more realistic use is wrapping something that gives you a cancel handle:

```swift
func observe() async throws -> [Change] {
    let query = CKQuery(recordType: "Item", predicate: NSPredicate(value: true))
    let operation = CKQueryOperation(query: query)

    return try await withTaskCancellationHandler {
        try await performOperation(operation)
    } onCancel: {
        operation.cancel()
    }
}
```


## `onCancel` handler constraints

The handler has signature `@Sendable () -> Void`, which imposes hard limits:

- **Synchronous only** – no `await` calls permitted.
- **No returns or throws** – cannot propagate values or errors back to the operation.
- **Sendable** – must use only thread-safe constructs. Cannot access actor-isolated state.

The handler can only *influence* the operation indirectly: cancel a stored `Task` handle, signal through a `Mutex`, or set a flag. It cannot short-circuit the operation itself.


## Early cancellation trap

If the task is **already cancelled** when `withTaskCancellationHandler` is entered, the `onCancel` handler fires *before* the operation closure runs. This is a common source of hangs:

```swift
// BUG: If the task is already cancelled, onCancel fires before
// the continuation is stored in `state`. The continuation is
// never resumed and the caller hangs forever.
await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
        state.continuation = continuation
    }
} onCancel: {
    state.continuation?.resume()  // nil – operation hasn't run yet
}
```

**Fix:** Check for cancellation *inside* a mutex-protected section, after storing the state the handler needs:

```swift
await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
        mutex.withLock { value in
            if Task.isCancelled {
                continuation.resume()
                return
            }
            value.continuation = continuation
        }
    }
} onCancel: {
    mutex.withLock { value in
        value.continuation?.resume()
        value.continuation = nil
    }
}
```

Checking `Task.isCancelled` outside the mutex creates a race where cancellation arrives between the check and the state store.


## Broken cancellation patterns

**Catching and ignoring `CancellationError`:**

```swift
// BROKEN: Retries or shows an alert for a normal lifecycle event.
catch {
    showAlert(error.localizedDescription)
}
```

Always prefer filtering out `CancellationError` before handling other errors. See `bug-patterns.md`.

**Forgetting to cancel stored tasks:**

```swift
// BROKEN: The task keeps running after the object is done with it.
class ViewModel {
    var loadTask: Task<Void, Never>?

    func load() {
        loadTask = Task { await fetchData() }
    }
}
```

Cancel the previous task before starting a new one, and cancel on teardown:

```swift
func load() {
    loadTask?.cancel()
    loadTask = Task { await fetchData() }
}

deinit {
    loadTask?.cancel()
}
```

**No cancellation checks in CPU-bound work:**

A tight computational loop with no `await` points will run to completion even if cancelled, because there are no suspension points where cancellation can take effect. Insert periodic `try Task.checkCancellation()` calls wherever it’s safe.
