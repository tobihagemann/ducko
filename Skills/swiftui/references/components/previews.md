# Previews

## Intent

Use previews to validate layout, state wiring, and injected dependencies without relying on a running app or live services.

## Core patterns

- Add `#Preview` coverage for the primary state plus important secondary states such as loading, empty, and error.
- Use deterministic fixtures, mocks, and sample data. Do not make previews depend on live network calls, real databases, or global singletons.
- Install required environment dependencies directly in the preview so the view can render in isolation.
- Keep preview setup close to the view until it becomes noisy; then extract lightweight preview helpers or fixtures.
- If a preview crashes, fix the state initialization or dependency wiring before expanding the feature further.

Prefer the `#Preview` macro (Swift 5.9+, Xcode 15+) for new code — it's less verbose than `PreviewProvider` and supports inline traits. `PreviewProvider` still works for older code.

## Example: simple preview states

```swift
#Preview("Loaded") {
  ProfileView(profile: .fixture)
}

#Preview("Empty") {
  ProfileView(profile: nil)
}
```

## Example: preview with injected dependencies

```swift
#Preview("Search results") {
  SearchView()
    .environment(SearchClient.preview(results: [.fixture, .fixture2]))
    .environment(Theme.preview)
}
```

## Static sample data on the model

Expose sample values as static properties on the model itself so any preview can reuse them without reconstructing values inline:

```swift
struct Item: Identifiable {
    let id: UUID
    var name: String
    var price: Double
}

extension Item {
    static let sample = Item(id: UUID(), name: "Widget", price: 9.99)

    static let samples: [Item] = [
        Item(id: UUID(), name: "Widget", price: 9.99),
        Item(id: UUID(), name: "Gadget", price: 19.99),
        Item(id: UUID(), name: "Doohickey", price: 4.99),
    ]
}

#Preview {
    ItemListView(items: Item.samples)
}
```

## Mock `@Observable` models

For views driven by an `@Observable` model (see [../state-management.md](../state-management.md) for fundamentals), expose pre-configured instances on the model itself, one per meaningful state:

```swift
@Observable
@MainActor
final class CartModel {
    var items: [Item] = []
    var isLoading = false

    static var preview: CartModel {
        let model = CartModel()
        model.items = Item.samples
        return model
    }

    static var emptyPreview: CartModel {
        CartModel()
    }

    static var loadingPreview: CartModel {
        let model = CartModel()
        model.isLoading = true
        return model
    }
}

#Preview("With Items") {
    CartView()
        .environment(CartModel.preview)
}

#Preview("Empty") {
    CartView()
        .environment(CartModel.emptyPreview)
}

#Preview("Loading") {
    CartView()
        .environment(CartModel.loadingPreview)
}
```

Inject environment values the view depends on so the preview reflects a realistic runtime context:

```swift
#Preview {
    OrderDetailView(order: .sample)
        .environment(CartModel.preview)
        .environment(\.locale, Locale(identifier: "ja_JP"))
        .environment(\.dynamicTypeSize, .xxxLarge)
}
```

## Mocking async data sources

When a view depends on a network or data service, give the dependency a protocol abstraction so previews can inject a synchronous mock that returns sample data immediately. Adapt this to whatever pattern the surrounding codebase already uses.

```swift
protocol DataFetching {
    func fetchItems() async throws -> [Item]
}

struct MockDataFetcher: DataFetching {
    var result: Result<[Item], Error> = .success(Item.samples)
    func fetchItems() async throws -> [Item] { try result.get() }
}

#Preview {
    ItemListView(fetcher: MockDataFetcher())
}

#Preview("Error State") {
    ItemListView(fetcher: MockDataFetcher(result: .failure(URLError(.notConnectedToInternet))))
}
```

## `@Previewable` property wrappers

`@Previewable` (iOS 18+, Xcode 16+) lets you use `@State`, `@FocusState`, and other property wrappers directly inside a `#Preview` block, removing the need for a wrapper view to host interactive state:

```swift
#Preview {
    @Previewable @State var isOn = false
    Toggle("Notifications", isOn: $isOn)
}
```

When seeding initial focus inside a preview, prefer `.defaultFocus` over writing to `@FocusState` from `.onAppear` — `.onAppear` can race the initial render and the assignment may be lost (see [../focus-patterns.md](../focus-patterns.md)):

```swift
#Preview {
    @Previewable @FocusState var isFocused: Bool

    TextField("Search", text: .constant(""))
        .focused($isFocused)
        .defaultFocus($isFocused, true)
}
```

If the project's minimum deployment target is below iOS 18, `@Previewable` is unavailable — fall back to a small wrapper view that hosts the `@State`.

## Common diagnostics

| Symptom | Cause | Fix |
|---|---|---|
| `#Preview` body type mismatch | The closure returns a non-`View` type | Make sure the final expression is a `View` |
| `@Previewable` only available in iOS 18+ | Using `@Previewable` with a lower deployment target | Use a wrapper view, or gate with `#available` |
| Preview crashes with "missing environment" | An `@Environment(SomeType.self)` value is not injected | Add `.environment(SomeType.preview)` to the preview |
| Preview hangs or renders blank | View depends on async data that never resolves | Inject a mock that returns immediately with sample data |
| `@MainActor`-isolated model accessed from non-isolated context | A preview helper touches main-actor-only API off the main actor | Mark the helper or the preview body `@MainActor` |

## Design choices to keep

- Cover at least one success path and one non-happy path.
- Install every required environment dependency so the view renders standalone.
- Keep fixtures stable and small enough to read quickly.
- Ensure the preview can render without network, auth, or app-global initialization.

## Pitfalls

- Do not hide preview crashes by making dependencies optional if the production view requires them.
- Avoid huge inline fixtures when a named sample is easier to read.
- Do not couple previews to global shared singletons unless the project has no alternative.
