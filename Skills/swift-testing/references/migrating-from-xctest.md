# Migrating from XCTest

If the project has existing tests written using XCTest, do *not* rewrite to Swift Testing unless requested. Even then, remember that XCTest supports UI testing, whereas Swift Testing does not.

Most things in XCTest have a direct equivalent in Swift Testing:

- `XCTAssertEqual(a, b)` maps to `#expect(a == b)`
- `XCTAssertLessThan(a, b)` maps to `#expect(a < b)`
- `XCTAssertThrowsError` maps to `#expect(throws:)`
- `XCTUnwrap(optional)` maps to `try #require(optional)` – both unwrap or fail, but `#require` works with any Boolean condition too.
- `XCTFail("message")` maps to `Issue.record("message")` – use this to manually record a test failure.
- `XCTAssertIdentical(a, b)` maps to `#expect(a === b)` – for checking two references point to the same object instance.

…and so on.

However, Swift Testing does *not* offer built-in float tolerance when checking if two floating-point values are *close enough* to be considered the same.

To do that, you must bring in Apple's Swift Numerics library and use its `isApproximatelyEqual(to:absoluteTolerance:)` method like this:

```swift
#expect(celsius.isApproximatelyEqual(to: 0, absoluteTolerance: 0.000001))
```

**Important:** Unless it is already imported into the project, do *not* add Swift Numerics as a library without first requesting permission from the user.


## Quick Reference Table

| XCTest | Swift Testing |
|--------|---------------|
| `class FooTests: XCTestCase` | `@Suite struct FooTests` |
| `func testFoo()` | `@Test func foo()` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertTrue(x)` | `#expect(x)` |
| `XCTAssertFalse(x)` | `#expect(!x)` |
| `XCTAssertNil(x)` | `#expect(x == nil)` |
| `XCTAssertNotNil(x)` | `#expect(x != nil)` or `try #require(x)` |
| `XCTAssertThrowsError` | `#expect(throws:)` |
| `XCTAssertNoThrow` | `#expect(throws: Never.self)` |
| `XCTAssertIdentical(a, b)` | `#expect(a === b)` |
| `XCTFail("message")` | `Issue.record("message")` |
| `XCTSkip("reason")` | trait `.disabled("reason")` or `.enabled(if:)` |
| `setUp()` | `init()` |
| `tearDown()` | `deinit` (class/actor suites) |


## Coexistence Strategy

Swift Testing and XCTest can coexist in the same target. Migrate incrementally; do not block migration on full rewrite. A single source file can import both `XCTest` and `Testing` during migration.

Keep XCTest where Swift Testing does not apply:

- UI automation (`XCUIApplication`)
- Performance APIs (`XCTMetric`)
- Objective-C-only tests

```swift
// Mixed-import file during migration
import XCTest
import Testing
```

Both frameworks are discovered and run by `swift test`.


## Converting from XCTest to Swift Testing

When converting XCTest code to Swift Testing:

1. **Convert assertions first** — keep the same broad structure: the same type names (class → struct), the same test methods (remove `test` prefix, add `@Test`), switch from old-style assertions to new-style expectations. Prefer mechanical, reviewable commits; use editor pattern-replace to accelerate common assertion conversions.
2. **Replace `test...` naming constraints** with explicit `@Test` annotations.
3. **Reorganize classes into suites** where helpful — use nested `@Suite` types instead of `// MARK:` comments.
4. **Add `#require` for preconditions** at the start of tests. Use `try #require(optional)` to replace `try XCTUnwrap(optional)`. Use `#require` instead of global `continueAfterFailure = false`.
5. **Collapse repetitive methods into parameterized tests** (`@Test(arguments:)`) where multiple tests share logic and differ only in input values.
6. **Add traits** where appropriate — `.timeLimit()`, `.enabled(if:)`, `.disabled("reason")`, `.tags(...)`, `.bug(...)` — to replace XCTest conventions such as skipping tests and grouping via test plans.


## Migration Examples

### Basic suite + test

```swift
// Before (XCTest)
class UserTests: XCTestCase {
    func testUserCreation() {
        let user = User(name: "Alice")
        XCTAssertEqual(user.name, "Alice")
        XCTAssertNotNil(user.id)
    }
}

// After (Swift Testing)
@Suite struct UserTests {
    @Test func userCreation() throws {
        let user = User(name: "Alice")
        #expect(user.name == "Alice")
        let id = try #require(user.id)
        #expect(!id.isEmpty)
    }
}
```

### Setup / teardown

```swift
// Before (XCTest)
class DatabaseTests: XCTestCase {
    var database: Database!

    override func setUp() {
        super.setUp()
        database = Database.inMemory()
    }

    override func tearDown() {
        database.close()
        database = nil
        super.tearDown()
    }

    func testInsert() { database.insert(record) }
}

// After (Swift Testing)
@Suite struct DatabaseTests {
    let database: Database

    init() throws {
        database = try Database.inMemory()
    }

    @Test func insert() {
        database.insert(record)
    }
}
```

Setup moves from `setUp()` patterns to suite `init()`. Teardown moves to `deinit` when using class/actor suites (struct suites get a fresh instance per test, so destructor cleanup is usually unnecessary).

### Async callback APIs

Prefer `await` directly for async APIs. Convert completion-handler APIs with `withCheckedContinuation` / `withCheckedThrowingContinuation`, or replace `XCTestExpectation` patterns with `confirmation`:

```swift
// Before (XCTest)
func testAsyncWithExpectation() {
    let expectation = XCTestExpectation(description: "Fetch")
    service.fetch { result in
        XCTAssertNotNil(result)
        expectation.fulfill()
    }
    wait(for: [expectation], timeout: 5)
}

// After (Swift Testing)
@Test func asyncWithConfirmation() async {
    await confirmation { confirm in
        service.fetch { result in
            #expect(result != nil)
            confirm()
        }
    }
}
```

### Parameterized migration

```swift
// Before (XCTest)
func testValidEmails() {
    let validEmails = ["a@b.com", "test@example.org"]
    for email in validEmails {
        XCTAssertTrue(EmailValidator.isValid(email), "\(email) should be valid")
    }
}

// After (Swift Testing)
@Test(arguments: ["a@b.com", "test@example.org"])
func validEmail(email: String) {
    #expect(EmailValidator.isValid(email))
}
```

### Skipping tests

```swift
// Before (XCTest)
func testPlatformSpecific() throws {
    #if !os(iOS)
    throw XCTSkip("iOS only")
    #endif
    // Test code
}

// After (Swift Testing)
@Test(.enabled(if: Platform.isIOS, "iOS only"))
func platformSpecific() { }
```

### Nested suite organization

```swift
// Before
class CartTests: XCTestCase {
    // MARK: - Adding Items
    func testAddSingleItem() { }
    func testAddMultipleItems() { }

    // MARK: - Removing Items
    func testRemoveItem() { }
}

// After
@Suite("Cart")
struct CartTests {
    @Suite("Adding Items")
    struct AddingTests {
        @Test func singleItem() { }
        @Test func multipleItems() { }
    }

    @Suite("Removing Items")
    struct RemovingTests {
        @Test func removeItem() { }
    }
}
```


## Suite Model Differences

- XCTest: class + `XCTestCase`.
- Swift Testing: struct / actor / class suites, explicit attributes, value-semantics-friendly defaults.
- XCTest sync tests default to main-actor behavior. Swift Testing runs tests on arbitrary tasks unless explicitly isolated (e.g. `@MainActor`) — do **not** reflexively mark every migrated test `@MainActor`.
- Setup moves from `setUp` to `init`; teardown moves to `deinit` where needed.


## Migration Strategy

1. **Start with leaf tests** — tests that don't depend on XCTest infrastructure.
2. **Migrate one file at a time** — keep changes reviewable.
3. **Run both simultaneously** — XCTest and Swift Testing coexist in a single target.
4. **Update CI configuration** — ensure both are run during migration.
5. **Remove XCTest after full migration** — clean up imports and dependencies.


## Common Pitfalls

- Migrating all files at once instead of phased migration.
- Keeping `continueAfterFailure` patterns instead of targeted `#require`.
- Marking every migrated test `@MainActor` unnecessarily.
- Mixing XCTest assertions in Swift Testing tests (and vice versa).
- Dropping `XCUIApplication` or `XCTMetric` tests during migration — Swift Testing does not support these; leave them on XCTest.
