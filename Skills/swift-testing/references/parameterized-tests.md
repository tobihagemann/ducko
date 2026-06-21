# Parameterized Tests

Test multiple inputs with a single test function.

## Basic Parameterization

```swift
@Test(arguments: [1, 2, 3, 4, 5])
func isPositive(number: Int) {
    #expect(number > 0)
}
```

## Multiple Arguments

### Using zip (Paired)

```swift
@Test(arguments: zip(
    ["hello", "world", "test"],
    [5, 5, 4]
))
func stringLength(string: String, expectedLength: Int) {
    #expect(string.count == expectedLength)
}
```

#### zip pitfalls to avoid

`zip` pairs by position, which makes it fragile when the two sides drift apart. For paired data, prefer an array of tuples or a dictionary (see below); reach for `zip` only when the inputs must stay as separate collections, and only with equal-length explicit arrays.

**Silent truncation:** `zip` stops at the shorter collection. If the two arrays differ in length, the extra elements are silently dropped — no compiler error, no test failure, just missing coverage.

```swift
// BAD: the fifth input is never tested
@Test(arguments: zip(
    [Status.active, .inactive, .pending, .banned, .suspended],
    ["Active", "Inactive", "Pending", "Banned"]  // one short
))
func statusLabel(status: Status, expected: String) {
    #expect(label(for: status) == expected)
}
```

**Case-order fragility with `CaseIterable`:** pairing two `allCases` arrays with `zip` breaks silently if enum cases are ever reordered (e.g., by alphabetizing).

```swift
// BAD: reordering either enum misaligns all pairs
enum Ingredient: CaseIterable { case rice, potato, egg }
enum Dish: CaseIterable { case onigiri, fries, omelette }

@Test(arguments: zip(Ingredient.allCases, Dish.allCases))
func cook(ingredient: Ingredient, into dish: Dish) {
    #expect(cook(ingredient) == dish)
}
```

### Paired Input Alternatives

When inputs and expected outputs must be paired, prefer these over `zip` to avoid the silent-truncation and case-ordering problems.

**Array of tuples (recommended):** pairs are co-located and impossible to misalign. Adding a new case forces a matching output to be written at the same time.

```swift
@Test(arguments: [
    (Ingredient.rice, Dish.onigiri),
    (.potato, .fries),
    (.egg, .omelette),
])
func cook(ingredient: Ingredient, into dish: Dish) {
    #expect(cook(ingredient) == dish)
}
```

**Dictionary arguments:** expresses a clear mapping; each entry is self-documenting. Requires `Hashable` keys.

```swift
@Test(arguments: [
    Ingredient.rice: Dish.onigiri,
    .potato: .fries,
    .egg: .omelette,
])
func cook(ingredient: Ingredient, into dish: Dish) {
    #expect(cook(ingredient) == dish)
}
```

**Fixed-size zip with `InlineArray` (Swift 6.2+):** a custom `zip` overload for `InlineArray` enforces equal-length arrays at compile time via a generic length parameter. This is not part of the standard library — you must define the helper yourself.

```swift
// Custom helper: `zip` for two `InlineArray` values of the same length.
func zip<let N: Int, A, B>(
    _ a: InlineArray<N, A>,
    _ b: InlineArray<N, B>
) -> Zip2Sequence<[A], [B]> {
    zip(Array(a), Array(b))
}

// Compile error if lengths differ — enforced at compile time
@Test(arguments: zip(
    InlineArray<2, Ingredient>(.rice, .potato),
    InlineArray<2, Dish>(.onigiri, .curry)
))
func cook(ingredient: Ingredient, into dish: Dish) {
    #expect(cook(ingredient) == dish)
}
```

### Cartesian Product (All Combinations)

```swift
@Test(arguments: [1, 2], ["a", "b"])
func combinations(number: Int, letter: String) {
    // Runs 4 times: (1,a), (1,b), (2,a), (2,b)
    #expect("\(number)\(letter)".isEmpty == false)
}
```

## Custom Test Cases

```swift
struct ValidationTestCase {
    let input: String
    let isValid: Bool
    let description: String
}

extension ValidationTestCase: CustomTestStringConvertible {
    var testDescription: String { description }
}

let validationCases = [
    ValidationTestCase(input: "valid@email.com", isValid: true, description: "valid email"),
    ValidationTestCase(input: "invalid", isValid: false, description: "missing @"),
    ValidationTestCase(input: "", isValid: false, description: "empty string"),
]

@Test(arguments: validationCases)
func validateEmail(testCase: ValidationTestCase) {
    let result = EmailValidator.validate(testCase.input)
    #expect(result == testCase.isValid)
}
```

## Enum Cases

```swift
enum Environment: CaseIterable {
    case development, staging, production
}

@Test(arguments: Environment.allCases)
func configurationLoads(environment: Environment) {
    let config = Configuration(environment: environment)
    #expect(config.isValid)
}
```

### When allCases Is Appropriate

Using `allCases` as arguments is valid for **property-based tests** — tests that verify a universal property holds for every member of a type. The key distinction: the expected result is derived from the *property being tested*, not from a hard-coded mapping (as in the `configurationLoads` example above, which asserts an invariant rather than a per-case value).

```swift
// GOOD: verifying a property holds for all orientations
@Test(
    "Rotating clockwise four times returns to the original orientation",
    arguments: Orientation.allCases
)
func fullRotation(orientation: Orientation) {
    #expect(
        orientation
            .rotated(.clockwise)
            .rotated(.clockwise)
            .rotated(.clockwise)
            .rotated(.clockwise)
        == orientation
    )
}
```

Avoid `allCases` when you need concrete, case-specific expected values — use explicit arrays of tuples or dictionaries instead (see Paired Input Alternatives above).

## Ranges

```swift
@Test(arguments: 1...100)
func withinRange(value: Int) {
    #expect(value >= 1 && value <= 100)
}
```

## Collection of Tuples

```swift
@Test(arguments: [
    ("2024-01-15", true),
    ("invalid", false),
    ("2024-13-45", false),
])
func dateValidation(dateString: String, shouldBeValid: Bool) {
    let isValid = DateValidator.validate(dateString)
    #expect(isValid == shouldBeValid)
}
```

## Avoiding Cartesian Explosion

Be careful with multiple argument lists:

```swift
// WARNING: This runs 1000 times (10 x 10 x 10)
@Test(arguments: 1...10, 1...10, 1...10)
func tooManyTests(a: Int, b: Int, c: Int) { }

// BETTER: Use zip for paired testing
@Test(arguments: zip(zip(inputs1, inputs2), expectedResults))
func pairedTest(inputs: ((Int, Int), Int)) { }
```

## Filtering Arguments

```swift
let testCases = (1...100).filter { $0 % 10 == 0 }

@Test(arguments: testCases)
func multiplesOfTen(value: Int) {
    #expect(value % 10 == 0)
}
```

## Complex Test Data

```swift
struct APITestCase: Sendable {
    let endpoint: String
    let method: HTTPMethod
    let expectedStatus: Int
    let body: Data?

    static let cases: [APITestCase] = [
        APITestCase(endpoint: "/users", method: .get, expectedStatus: 200, body: nil),
        APITestCase(endpoint: "/users", method: .post, expectedStatus: 201, body: validUserData),
        APITestCase(endpoint: "/users/999", method: .get, expectedStatus: 404, body: nil),
    ]
}

@Test(arguments: APITestCase.cases)
func apiEndpoint(testCase: APITestCase) async throws {
    let response = try await client.request(
        endpoint: testCase.endpoint,
        method: testCase.method,
        body: testCase.body
    )
    #expect(response.statusCode == testCase.expectedStatus)
}
```

## Arguments Must Be Sendable

`@Test(arguments:)` elements cross into the test function's isolation domain, so every argument type must be `Sendable`. Most value types are, but `KeyPath` is **not** reliably `Sendable` — it cannot be used as a parameter:

```swift
// FAILS to compile: "type 'KeyPath<Held, Bool>' does not conform to 'Sendable' protocol ...
// crossing of an isolation boundary requires parameter and result types to conform to 'Sendable'"
@Test(arguments: [(UInt16(126), \Held.w), (UInt16(125), \Held.s)])
func arrowMapsToBit(keyCode: UInt16, bit: KeyPath<Held, Bool>) { }
```

Pass a concrete `Sendable` value (e.g. the expected result) instead, or replace the parameterization with explicit per-case assertions in a single test:

```swift
// Pass the expected value, not a KeyPath.
@Test(arguments: [(UInt16(126), Held(w: true)), (UInt16(125), Held(s: true))])
func arrowMapsToBit(keyCode: UInt16, expected: Held) {
    var sampler = Sampler()
    sampler.press(keyCode)
    #expect(sampler.held == expected)
}
```

## Common Pitfalls

**Derived expected values masking bugs:** when the expected value is derived from the same input expression as the system under test, both sides shift together and bugs pass silently. Use concrete literals in `#expect` for case-specific expectations.

```swift
// BAD: if format(day) returns "monday" instead of "Monday", this test still
//      passes because rawValue has the same casing bug.
@Test(arguments: Day.allCases)
func dayLabel(day: Day) {
    #expect(format(day) == day.rawValue)
}

// GOOD: each expectation is an independent data point
@Test(arguments: [
    (Day.monday, "Monday"),
    (.friday, "Friday"),
])
func dayLabel(day: Day, expected: String) {
    #expect(format(day) == expected)
}
```

**Control flow in test bodies:** `if`/`switch` inside a parameterized test body mirrors implementation logic. Tests that branch the same way as production code verify themselves rather than the behavior independently. Split the special case into its own test instead.

```swift
// BAD: mirrors implementation — not independent verification
@Test(arguments: Day.allCases)
func greeting(day: Day) {
    if day == .friday {
        #expect(greet(day) == "TGIF!")
    } else {
        #expect(greet(day) == "Hello, \(day)!")
    }
}

// GOOD: separate the special case
@Test func fridayGreeting() {
    #expect(greet(.friday) == "TGIF!")
}

@Test(arguments: [Day.monday, .tuesday, .wednesday, .thursday, .saturday, .sunday])
func standardGreeting(day: Day) {
    #expect(greet(day) == "Hello, \(day)!")
}
```

## Best Practices

1. **Keep test cases focused**: Each should test one thing
2. **Use descriptive names**: Implement `CustomTestStringConvertible`
3. **Model paired data as tuples or dictionaries**: Prefer arrays of tuples/dictionaries over `zip` for paired inputs; use `zip` only with equal-length explicit arrays when the inputs must stay separate collections
4. **Group related cases**: Create structs for complex scenarios
5. **Make test data Sendable**: Required for parallel execution
6. **Keep sensitive fields out of arguments**: Swift Testing reflects argument values into test names, test reports, and CI logs. Passing a `Sendable` struct that contains a password, token, or other secret leaks the secret into reflection-based displays. For cases like XMPP `Credential`-style structs, pass an opaque label/ID as the argument and look up the secret inside the test body — or implement `CustomTestStringConvertible` to strip the sensitive fields from the displayed name.

```swift
// GOOD: Clear, paired test cases
@Test(arguments: zip(["a", "ab", "abc"], [1, 2, 3]))
func stringLength(string: String, expected: Int) {
    #expect(string.count == expected)
}

// BAD: Cartesian product, unclear intent
@Test(arguments: ["a", "ab", "abc"], [1, 2, 3])
func unclearTest(string: String, number: Int) { }
```
