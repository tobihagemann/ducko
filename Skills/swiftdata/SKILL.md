---
name: swiftdata
description: Expert guidance for designing, writing, reviewing, and debugging SwiftData persistence in Swift and SwiftUI apps. Use when working with @Model schemas, @Relationship/@Attribute rules, @Query or FetchDescriptor data access, ModelContainer/ModelContext configuration, SchemaMigrationPlan/history APIs, ModelActor concurrency isolation, CloudKit sync, or Core Data adoption/coexistence.
license: MIT
---

Write and review SwiftData code for correctness, modern API usage, data integrity, migration safety, sync correctness, and predictable concurrency behavior. Report only genuine problems — do not nitpick or invent issues.

Review process:

1. Check for core SwiftData issues using [references/core-rules.md](references/core-rules.md).
2. Check `@Model` shape, attributes, and uniqueness using [references/modeling-and-schema.md](references/modeling-and-schema.md).
3. Check context lifecycle, inserts, saves, and undo using [references/model-context-and-lifecycle.md](references/model-context-and-lifecycle.md).
4. Check that predicates are safe and supported using [references/predicates.md](references/predicates.md).
5. Check filtering/sorting/query patterns using [references/querying-and-fetching.md](references/querying-and-fetching.md).
6. Check relationships and (iOS 26+) inheritance using [references/relationships-and-inheritance.md](references/relationships-and-inheritance.md) and [references/class-inheritance.md](references/class-inheritance.md).
7. If schema changes are in scope, check migration safety using [references/migrations-and-history.md](references/migrations-and-history.md).
8. If the project uses CloudKit, check CloudKit constraints using [references/cloudkit.md](references/cloudkit.md) and sync behavior using [references/cloudkit-sync.md](references/cloudkit-sync.md).
9. If the project targets iOS 18+, check for indexing opportunities using [references/indexing.md](references/indexing.md).
10. If any work runs off the main actor, check isolation using [references/concurrency-and-actors.md](references/concurrency-and-actors.md).
11. If coexisting with Core Data, check adoption strategy using [references/core-data-adoption.md](references/core-data-adoption.md).
12. For diagnostics and API availability checks, use [references/troubleshooting-and-updates.md](references/troubleshooting-and-updates.md).
13. For end-to-end execution examples, use [references/implementation-playbooks.md](references/implementation-playbooks.md).

If doing partial work, load only the relevant reference files.


## Core Instructions

- Target Swift 6.2 or later, using modern Swift concurrency.
- The user strongly prefers SwiftData. Do not suggest Core Data functionality unless it is a feature that cannot be solved with SwiftData.
- Do not introduce third-party frameworks without asking first.
- Use a consistent project structure, with folder layout determined by app features.
- Identify the minimum deployment target before recommending APIs (notably `#Index`, `#Unique`, `HistoryDescriptor`, `DataStore`, inheritance examples).
- Confirm the app has real `ModelContainer` wiring before debugging data issues; without it, inserts fail and fetches are empty.
- Distinguish main-actor UI operations from background persistence operations; never assume one context fits both.
- Treat schema changes as migration changes: evaluate lightweight migration first, then `SchemaMigrationPlan` when needed.
- For CloudKit-enabled apps, verify schema compatibility constraints before proposing model changes.
- Prefer deterministic query definitions (shared predicates, explicit sort order, bounded fetches) over ad hoc filtering in views.
- Use persistent history tokens when reading cross-process changes; delete stale history to avoid storage growth.
- In code reviews, prioritize data loss risk, accidental mass deletion, sync divergence, and context-isolation bugs over style changes.


## Project Intake (Before Advising)

- Deployment targets for iOS, iPadOS, macOS, watchOS, and visionOS.
- Container setup: `.modelContainer(...)` modifier or manual `ModelContainer(...)`.
- Autosave expectations and whether explicit `save()` is required.
- Undo enablement (`isUndoEnabled`) and whether operations occur on `mainContext` or custom contexts.
- CloudKit capabilities and chosen container strategy (`automatic`, `.private(...)`, `.none`).
- App group storage requirements.
- Core Data coexistence in scope.
- Whether schema changes must be backward-compatible with existing user data.

Quick analysis commands:

- Container setup: `rg "modelContainer\(|ModelContainer\(" -n`
- Model definitions: `rg "^@Model|#Unique|#Index|@Relationship|@Attribute|@Transient" -n`
- Context usage: `rg "modelContext|mainContext|ModelContext\(" -n`
- Migrations and history: `rg "SchemaMigrationPlan|VersionedSchema|MigrationStage|fetchHistory|deleteHistory|historyToken" -n`
- CloudKit and app groups: `rg "cloudKitDatabase|iCloud|CloudKit|groupContainer|AppGroup|NSPersistentCloudKitContainer" -n`


## Triage-First Playbook

Common problems → next best move:

- **Insert fails or fetch is always empty** → confirm `.modelContainer(...)` is attached at app or window root and the model type is included.
- **Duplicate rows after network refresh** → add `@Attribute(.unique)` or `#Unique` constraints and rely on insert-upsert behavior.
- **Unexpected data loss during delete** → audit delete rules (`.cascade` vs `.nullify`) and check for unbounded `delete(model:where:)`.
- **Undo or redo does nothing** → ensure `isUndoEnabled: true` and that changes are saved via `mainContext` (not only background context).
- **CloudKit sync not behaving** → check capabilities, remote notifications, and CloudKit schema compatibility; explicitly set `cloudKitDatabase` if multiple containers exist.
- **Widget or App Intent changes not reflected** → use persistent history (`fetchHistory`) with token + author filtering.
- **`historyTokenExpired` appears** → reset local token strategy and rebootstrap change consumption from a safe point.
- **Query results expensive or unstable** → use shared predicate builders, explicit sorting, and bounded `FetchDescriptor` settings.


## Anti-Patterns (Reject by Default)

- Building persistence logic before validating container wiring.
- Performing broad deletes without predicate review and confirmation.
- Mixing UI-driven editing and background write pipelines without isolation boundaries.
- Relying on ad hoc in-memory filtering instead of store-backed predicates.
- Enabling CloudKit sync without capability setup and schema compatibility checks.
- Shipping schema changes without migration rehearsal on existing user data.
- Consuming history without token persistence and cleanup policy.
- Using `isEmpty == false` in `#Predicate` (runtime crash) — use `!` instead.
- Placing `@Query` anywhere other than a SwiftUI view.


## Core Patterns

### App-level container wiring (SwiftUI)

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [Trip.self, Accommodation.self])
    }
}
```

### Manual container configuration

```swift
let config = ModelConfiguration(isStoredInMemoryOnly: false)
let container = try ModelContainer(
    for: Trip.self,
    Accommodation.self,
    configurations: config
)
```

### Dynamic query in a view initializer

```swift
struct TripListView: View {
    @Query private var trips: [Trip]

    init(searchText: String) {
        let predicate = #Predicate<Trip> {
            searchText.isEmpty || $0.name.localizedStandardContains(searchText)
        }
        _trips = Query(filter: predicate, sort: \.startDate, order: .forward)
    }

    var body: some View { List(trips) { Text($0.name) } }
}
```

### Safe batch delete pattern

```swift
do {
    try modelContext.delete(
        model: Trip.self,
        where: #Predicate { $0.endDate < .now },
        includeSubclasses: true
    )
    try modelContext.save()
} catch {
    // Handle delete and save failures.
}
```


## Best Practices Summary

1. Keep model code as the source of truth; avoid hidden schema assumptions.
2. Apply explicit uniqueness and indexing strategy for large or frequently queried datasets.
3. Insert root models and let SwiftData traverse relationship graphs automatically.
4. Keep query behavior deterministic with explicit predicates and sort descriptors.
5. Bound fetches (`fetchLimit`, offsets, identifier-only fetches) for scalability.
6. Treat delete rules as business rules; review them during schema changes.
7. Use `ModelConfiguration` for environment-specific behavior (in-memory tests, CloudKit, app groups, read-only stores).
8. Handle history as an operational system: token persistence, filtering, and cleanup.
9. Use model actors or isolated contexts for non-UI persistence work.
10. Gate recommendations by API availability and deployment target.


## Verification Checklist (After Changes)

- Build succeeds for target platforms and minimum deployment versions.
- CRUD tests pass with real store and in-memory store.
- Relationship deletes behave as intended (`cascade`, `nullify`, and others).
- Query behavior is stable with realistic datasets and sort/filter combinations.
- Migration path is validated on pre-existing data (not only clean installs).
- CloudKit behavior is validated in a development container before release.
- Cross-process changes (widgets, intents, extensions) are observed correctly.
- Error paths and rollback behavior are covered for destructive operations.


## Output Format

If the user asks for a review, organize findings by file. For each issue:

1. State the file and relevant line(s).
2. Name the rule being violated.
3. Show a brief before/after code fix.

Skip files with no issues. End with a prioritized summary of the most impactful changes to make first.

If the user asks you to write or improve code, follow the same rules above but make the changes directly instead of returning a findings report.

Example output:

### Destination.swift

**Line 8: Add an explicit delete rule for relationships.**

```swift
// Before
var sights: [Sight]

// After
@Relationship(deleteRule: .cascade, inverse: \Sight.destination) var sights: [Sight]
```

**Line 22: Do not use `isEmpty == false` in predicates – it crashes at runtime. Use `!` instead.**

```swift
// Before
#Predicate<Destination> { $0.sights.isEmpty == false }

// After
#Predicate<Destination> { !$0.sights.isEmpty }
```

### DestinationListView.swift

**Line 5: `@Query` must only be used inside SwiftUI views.**

```swift
// Before
class DestinationStore {
    @Query var destinations: [Destination]
}

// After
class DestinationStore {
    var modelContext: ModelContext

    func fetchDestinations() throws -> [Destination] {
        try modelContext.fetch(FetchDescriptor<Destination>())
    }
}
```

### Summary

1. **Data loss (high):** Missing delete rule on line 8 of Destination.swift means sights will be orphaned when a destination is deleted.
2. **Crash (high):** `isEmpty == false` on line 22 will crash at runtime – use `!isEmpty` instead.
3. **Incorrect behavior (high):** `@Query` on line 5 of DestinationListView.swift only works inside SwiftUI views.

End of example.


## References

- [references/core-rules.md](references/core-rules.md) — autosaving, relationships, delete rules, property restrictions, and FetchDescriptor optimization.
- [references/modeling-and-schema.md](references/modeling-and-schema.md) — `@Model` shape, attributes, uniqueness, indexing strategy.
- [references/model-context-and-lifecycle.md](references/model-context-and-lifecycle.md) — insert/update/delete lifecycle, context correctness, undo.
- [references/predicates.md](references/predicates.md) — supported predicate operations, dangerous patterns that crash at runtime, and unsupported methods.
- [references/querying-and-fetching.md](references/querying-and-fetching.md) — filtering, sorting, dynamic list behavior, FetchDescriptor tuning.
- [references/relationships-and-inheritance.md](references/relationships-and-inheritance.md) — relationship modeling, delete rules, inheritance patterns.
- [references/class-inheritance.md](references/class-inheritance.md) — model subclassing for iOS 26+, including @available requirements, schema setup, and predicate filtering.
- [references/migrations-and-history.md](references/migrations-and-history.md) — lightweight migrations, `SchemaMigrationPlan`, persistent history.
- [references/cloudkit.md](references/cloudkit.md) — CloudKit-specific schema constraints including uniqueness, optionality, and eventual consistency.
- [references/cloudkit-sync.md](references/cloudkit-sync.md) — sync debugging, capability setup, remote notifications, container strategy.
- [references/indexing.md](references/indexing.md) — database indexing for iOS 18+, including single and compound property indexes.
- [references/concurrency-and-actors.md](references/concurrency-and-actors.md) — `ModelActor`, isolated contexts, safe background persistence patterns.
- [references/core-data-adoption.md](references/core-data-adoption.md) — incremental migration from Core Data, coexistence strategies.
- [references/troubleshooting-and-updates.md](references/troubleshooting-and-updates.md) — diagnostics, API availability checks, recent SwiftData updates.
- [references/implementation-playbooks.md](references/implementation-playbooks.md) — end-to-end execution playbooks for concrete tasks.
