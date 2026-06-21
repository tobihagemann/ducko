# Test Doubles

Test doubles help isolate the system under test (SUT) from side effects. Terminology from [Martin Fowler's "Mocks Aren't Stubs"](https://martinfowler.com/articles/mocksArentStubs.html).

## State vs Behavior Verification

| Approach | Description | Test Doubles Used |
|----------|-------------|-------------------|
| **State Verification** | Assert on final state after action | Stubs, Fakes, Spies |
| **Behavior Verification** | Verify correct calls to collaborators | Mocks |

**Prefer state verification** - simpler, less brittle tests.

## Dummy

A dummy doesn't do anything - just a placeholder:

```swift
struct UserServiceDummy: UserServiceProtocol {
    func login(_ user: User, completion: (Result<Void, Error>) -> Void) {
        // Does nothing
    }
}
```

## Fake

Working implementation with shortcuts (e.g., in-memory database):

```swift
final class FavoritesManagerFake: FavoritesManagerProtocol {
    var favorites: [Movie] = []

    func add(_ movie: Movie) throws {
        guard !favorites.contains(where: { $0.id == movie.id }) else {
            throw FavoritesError.alreadyExists
        }
        favorites.append(movie)
    }

    func remove(_ movie: Movie) throws {
        guard let index = favorites.firstIndex(where: { $0.id == movie.id }) else {
            throw FavoritesError.notFound
        }
        favorites.remove(at: index)
    }
}
```

## Stub

Returns pre-configured values:

```swift
final class PostsServiceStub: PostsServiceProtocol {
    var fetchAllResultToBeReturned: Result<[Post], Error> = .success([])

    func fetchAll() async throws -> [Post] {
        try fetchAllResultToBeReturned.get()
    }
}

// Naming: [methodName]ToBeReturned
```

## Spy

Records calls for verification:

```swift
final class SafeStorageSpy: SafeStorageProtocol, @unchecked Sendable {
    private(set) var storeUserDataCalled = false
    private(set) var userPassed: User?
    private(set) var storeUserDataCount = 0

    func storeUserData(_ user: User) {
        storeUserDataCalled = true
        storeUserDataCount += 1
        userPassed = user
    }
}

// Naming conventions:
// - Method called: [name]Called (Bool)
// - Parameter captured: [name]Passed
// - Call count: [name]Count (Int)
// - All should be private(set)
```

## SpyingStub (Most Common)

Combines Stub + Spy - this is what Swift developers usually call "Mock":

```swift
final class PersonalRecordsRepositorySpyingStub: PersonalRecordsRepositoryProtocol, @unchecked Sendable {
    // Spy: Captured calls
    private(set) var savedRecords: [PersonalRecord] = []
    private(set) var deletedIds: [UUID] = []
    private(set) var getAllCalled = false

    // Stub: Configurable responses
    var recordsToReturn: [PersonalRecord] = []
    var errorToThrow: Error?

    func getAll() async throws -> [PersonalRecord] {
        getAllCalled = true
        if let error = errorToThrow { throw error }
        return recordsToReturn
    }

    func save(_ record: PersonalRecord) async throws {
        if let error = errorToThrow { throw error }
        savedRecords.append(record)
    }

    func delete(id: UUID) async throws {
        if let error = errorToThrow { throw error }
        deletedIds.append(id)
    }
}

// Naming: [ProtocolName]SpyingStub
```

## True Mock (Fowler Definition)

Pre-programmed with expectations, self-verifies:

```swift
final class UserServiceMock: UserServiceProtocol {
    struct Expectation: Equatable {
        let method: String
        let userId: String?
    }

    private var expectations: [Expectation] = []
    private var actualCalls: [Expectation] = []
    private var returnValues: [String: User] = [:]

    // Setup (before test)
    func expectGetUser(id: String, returning user: User) {
        expectations.append(Expectation(method: "getUser", userId: id))
        returnValues[id] = user
    }

    // Protocol implementation
    func getUser(id: String) async throws -> User {
        let call = Expectation(method: "getUser", userId: id)
        actualCalls.append(call)

        guard expectations.contains(call) else {
            fatalError("Unexpected call: getUser(id: \(id))")
        }

        guard let user = returnValues[id] else {
            throw UserError.notFound
        }
        return user
    }

    // Verification (after test)
    func verify() {
        assert(expectations == actualCalls)
    }
}

// Usage
@Test("fetches user with expected ID")
func fetchesExpectedUser() async throws {
    let mock = UserServiceMock()
    mock.expectGetUser(id: "123", returning: User.fixture())

    await sut.loadProfile(userId: "123")

    mock.verify()  // Self-verifies
}
```

**Use true mocks when**:
- Testing interaction protocols (delegates)
- Verifying exact call sequences
- Testing that calls are NOT made

## Failings (Unimplemented)

Fail if unexpectedly called:

```swift
import XCTestDynamicOverlay

struct FailingNetworkService: NetworkServiceProtocol {
    func fetchData(from url: URL) async throws -> Data {
        XCTFail("fetchData(from:) was not expected to be called!")
        fatalError()
    }
}
```

With swift-dependencies:

```swift
extension PersonalRecordsRepository: TestDependencyKey {
    static let testValue = PersonalRecordsRepository(
        getAll: unimplemented("\(Self.self).getAll"),
        save: unimplemented("\(Self.self).save")
    )
}
```

## Choosing the Right Double

| Need | Use |
|------|-----|
| Fill a parameter | Dummy |
| Working lightweight implementation | Fake |
| Control return values | Stub |
| Verify calls were made | Spy |
| Both control and verify | SpyingStub |
| Verify exact interactions | Mock |
| Catch unexpected usage | Failing |

## Placement

Place test doubles **close to the interface**, not in test targets:

```swift
// In ModuleName-Interface/Sources/...

public protocol MyServiceProtocol: Sendable {
    func doSomething() async throws
}

#if DEBUG
public final class MyServiceSpyingStub: MyServiceProtocol {
    // Implementation
}
#endif
```

Benefits:
- Available to all test targets
- Lives with the contract it implements
- Zero production overhead with `#if DEBUG`

## Actor dependencies need a protocol seam

Swift `actor`s are not subclassable, so a concrete-actor type used as a dependency has no subclass-mock seam. Tests can construct the real actor, but stubbing one method while leaving the rest real is impossible without a protocol.

Pattern: declare a `Sendable` protocol with `async` requirements, have the production actor conform, and type the dependency as `any Protocol`:

```swift
public protocol AdminWorldRouter: Sendable {
    func loggedInPlayerCount() async -> Int
    func kickByCharacterName(_ name: String) async -> Bool
}

public actor WorldRouter: AdminWorldRouter { ... }

// Dependency bag types against the protocol:
public struct AdminConnectionDependencies {
    public let worldRouter: any AdminWorldRouter
}

// Tests substitute a struct stub:
struct StubAdminWorldRouter: AdminWorldRouter {
    func loggedInPlayerCount() async -> Int { 12 }
    func kickByCharacterName(_ name: String) async -> Bool { true }
}
```

Make every protocol requirement `async`. Actor-isolated methods automatically satisfy `async` requirements via cross-actor isolation hops; `nonisolated` is only needed for non-`async` requirements, which forces actor-isolated state out of reach. Keep the protocol surface narrow — only the methods the consumer actually calls — so the stub stays small.
