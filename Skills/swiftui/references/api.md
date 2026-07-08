# Using modern SwiftUI API

- Always use `foregroundStyle()` instead of `foregroundColor()`.
- Always use `clipShape(.rect(cornerRadius:))` instead of `cornerRadius()`.
- Always use the `Tab` API instead of `tabItem()`.
- Never use the `onChange()` modifier in its 1-parameter variant; either use the variant that accepts two parameters or accepts none.
- Do not use `GeometryReader` if a newer alternative works: `containerRelativeFrame()`, `visualEffect()`, or the `Layout` protocol. Flag `GeometryReader` usage and suggest the modern alternative.
- When designing haptic effects, prefer using `sensoryFeedback()` over older UIKit APIs such as `UIImpactFeedbackGenerator`.
- Use the `@Entry` macro to define custom `EnvironmentValues`, `FocusValues`, `Transaction`, and `ContainerValues` keys. This replaces the legacy pattern of manually creating a type conforming to (for example) `EnvironmentKey` with a `defaultValue`, then extending `EnvironmentValues` with a computed property.
- Strongly prefer `overlay(alignment:content:)` over the deprecated `overlay(_:alignment:)`. For example, use `.overlay { Text("Hello, world!") }` rather than `.overlay(Text("Hello, world!"))`.
- Never use `.navigationBarLeading` and `.navigationBarTrailing` for toolbar item placement; they are deprecated. The correct, modern placements are `.topBarLeading` and `.topBarTrailing`.
- Prefer to rely on automatic grammar agreement when dealing with English, French, German, Portuguese, Spanish, and Italian. For example, use `Text("^[\(people) person](inflect: true)")` to show a number of people.
- You can fill and stroke a shape with two chained modifiers; you do *not* need an overlay for the stroke. The overlay was required previously, but this is fixed in iOS 17 and later.
- When referencing images from an asset catalog, prefer the generated symbol asset API when the project is configured to use them: `Image(.avatar)` rather than `Image("avatar")`.
- When targeting iOS 26 and later, SwiftUI has a native `WebView` view type that replaces almost all uses of hand-wrapped `WKWebView` inside `UIViewRepresentable`. To use it, make sure to include `import WebKit`.
- `ForEach` over an `enumerated()` sequence should not convert to an array first. Use `ForEach(items.enumerated(), id: \.element.id)` directly.
- When hiding scroll indicators, use `.scrollIndicators(.hidden)` rather than `showsIndicators: false` in the initializer.
- Never use `Text` concatenation with `+`.

For example, the usage of `+` here is bad and deprecated:

```swift
Text("Hello").foregroundStyle(.red)
+
Text("World").foregroundStyle(.blue)
```

Instead, use text interpolation like this:

```swift
let red = Text("Hello").foregroundStyle(.red)
let blue = Text("World").foregroundStyle(.blue)
Text("\(red)\(blue)")
```


## Using ObservableObject

If using `ObservableObject` is absolutely required – for example if you are trying to create a debouncer using a Combine publisher – you should always make sure `import Combine` is added. This was previously provided through SwiftUI, but that is no longer the case.


## Handling soft-deprecated APIs

This section covers *how to behave* when you encounter soft-deprecated SwiftUI APIs. For the deprecated-to-modern transitions themselves, see the table above and [modern-apis.md](modern-apis.md).

### What "soft-deprecated" means

A soft-deprecated API is marked deprecated in the SDK headers but with a placeholder deprecation version (`100000.0`) that suppresses compiler warnings. It still compiles and works correctly — it just signals that the API shouldn't be used in new code. Examples include `NavigationView` (use `NavigationStack` / `NavigationSplitView`), `ActionSheet` / `Alert` (use the `.confirmationDialog` / `.alert` modifiers), `MagnificationGesture` (renamed `MagnifyGesture`), and `PresentationMode` (use `\.dismiss`).

Because these still work, treat them as **informational**, not urgent.

### Scoping rule — read this first

All soft-deprecation guidance is scoped to the code you are **directly modifying**. If a file contains several views and the task touches only one, the other views are out of scope.

- Only discuss the view(s) you actually edited.
- Do not mention, flag, or offer to migrate soft-deprecated APIs in code you weren't asked to change — including trailing "while I'm here, want me to migrate `OtherView`?" questions.
- This takes precedence over any prompt asking for "observations" or "other notes."

Mentioning soft-deprecated APIs in untouched code creates noise, distracts from the task, and pressures the user into unrelated work.

### When generating new code

Never introduce a new usage of a soft-deprecated API. If you're unsure whether an API is soft-deprecated, check [modern-apis.md](modern-apis.md) before recommending it — any API that worked in a prior release could have been soft-deprecated since.

### When asked to review, refactor, modernize, or clean up

Point out soft-deprecated APIs in the code under review and suggest the modern replacement. Keep the tone informational — these still compile and run, so frame migration as an improvement, not a bug fix.

### When asked to add a feature or fix a bug

If the view you're editing already uses a soft-deprecated API, **keep it as-is** in your change. Don't silently swap `NavigationView` for `NavigationStack` while adding a search bar — that produces unexpected diffs, risks regressions (state resets, navigation behavior changes), and makes the change harder to review. After delivering the requested change, you may add a brief one-line offer to migrate as a separate step.

If a *different* view in the same file uses a soft-deprecated API, ignore it entirely (see the scoping rule).

### General guidance

- Never introduce new usages of soft-deprecated APIs in code written from scratch.
- Don't proactively scan a codebase for soft-deprecated APIs — only notice them when they appear in code you're directly modifying for the user's request.
- Migrations are real edits with behavioral risk; they belong in their own focused change, not bundled into unrelated work.
