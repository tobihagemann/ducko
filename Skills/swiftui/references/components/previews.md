# Previews

## Intent

Use previews to validate layout, state wiring, and injected dependencies without relying on a running app or live services.

## Core patterns

- Add `#Preview` coverage for the primary state plus important secondary states such as loading, empty, and error.
- Use deterministic fixtures, mocks, and sample data. Do not make previews depend on live network calls, real databases, or global singletons.
- Install required environment dependencies directly in the preview so the view can render in isolation.
- Keep preview setup close to the view until it becomes noisy; then extract lightweight preview helpers or fixtures.
- If a preview crashes, fix the state initialization or dependency wiring before expanding the feature further.

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

## Design choices to keep

- Cover at least one success path and one non-happy path.
- Install every required environment dependency so the view renders standalone.
- Keep fixtures stable and small enough to read quickly.
- Ensure the preview can render without network, auth, or app-global initialization.

## Pitfalls

- Do not hide preview crashes by making dependencies optional if the production view requires them.
- Avoid huge inline fixtures when a named sample is easier to read.
- Do not couple previews to global shared singletons unless the project has no alternative.
