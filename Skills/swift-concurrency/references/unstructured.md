# Unstructured concurrency

## Task vs `Task.detached`

You should already know that `Task {}` inherits the caller's actor isolation, whereas `Task.detached {}` does not.

```swift
@MainActor
func example() {
    Task {
        // Still on MainActor; safe to update UI here.
        label.text = "Done"
    }

    Task.detached {
        // Not on MainActor; updating UI here is a bug.
        // Use this for genuinely independent background work.
    }
}
```

However, what you are less likely to know is this: `Task.detached` is rarely the right choice.

In Swift 6.2+, prefer `@concurrent` over `Task.detached` when the goal is to leave the caller's actor. `Task.detached` discards `@TaskLocal` values and priority inheritance, which is almost never what you want. `@concurrent` opts out of actor isolation while preserving task-local state and priority.

```swift
// PREFER: Leaves the caller's actor, keeps @TaskLocal values and priority.
@concurrent
func analyzeData(_ data: [Double]) async -> Result { ... }

// AVOID: Discards @TaskLocal values and priority. Use only when that is the explicit intent.
Task.detached {
    await analyzeData(data)
}
```

Only use `Task.detached` when you specifically need to shed task-local values or priority — and document why.


## Cancellation is cooperative

Always remember that cancelling a task does not stop its code – the task's body must check for cancellation explicitly.

```swift
func processItems(_ items: [Item]) async throws {
    for item in items {
        // Check before expensive work
        try Task.checkCancellation()
        await process(item)
    }
}
```

- `Task.checkCancellation()` throws `CancellationError` if cancelled.
- `Task.isCancelled` returns a Bool for non-throwing contexts.
- `task.cancel()` only sets the flag – it does not interrupt execution.

This means it’s important to ensure complex tasks regularly check for cancellation at safe intervals.

For legacy APIs that offer their own cancel mechanism, use `withTaskCancellationHandler` to bridge Swift's cooperative cancellation to the underlying API. See `cancellation.md` for details and examples.


## `Task.immediate` (Swift 6.2)

For `Task.immediate` details, see `new-features.md`. For most cases, regular `Task {}` is still the right choice.


## When `Task {}` is a code smell

Creating a `Task {}` to call an async function from a synchronous context is sometimes necessary (e.g., in a button action). But watch for these anti-patterns:

- **Task inside `onAppear()`**: Never create a `Task` inside a SwiftUI `onAppear()`. Use the `.task()` modifier instead, because it handles cancellation on disappear automatically.
- **Task to bridge sync → async in a function that could itself be async**: If the caller can be made async, do that instead of wrapping in `Task {}`.
- **Ignoring the return value of a throwing task**: The error is silently lost. At minimum, handle errors inside the task closure.
