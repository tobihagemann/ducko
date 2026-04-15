import DuckoCore
import DuckoXMPP
import Foundation
import Logging
import Testing

private let log = Logger(label: "im.ducko.integrationtests.harness")

/// Lifecycle owner for an integration test: a single shared `AppEnvironment`,
/// per-account event streams, and LIFO cleanup actions.
///
/// Use `TestHarness.withHarness { harness in ... }` to guarantee teardown runs
/// in both success and failure paths (Swift `defer` cannot await).
@MainActor
final class TestHarness {
    let environment: AppEnvironment
    private(set) var accounts: [String: ConnectedAccount] = [:]

    private let router: EventRouter
    private let tempDir: URL
    private var cleanupActions: [@Sendable () async -> Void] = []

    private init(environment: AppEnvironment, router: EventRouter, tempDir: URL) {
        self.environment = environment
        self.router = router
        self.tempDir = tempDir
    }

    // MARK: - Lifecycle

    /// Runs `body` with a fresh harness, awaiting teardown on both success and failure paths.
    static func withHarness(_ body: (TestHarness) async throws -> Void) async throws {
        let router = EventRouter()
        let (environment, tempDir) = try TestEnvironmentFactory.makeEnvironment { event, accountID in
            MainActor.assumeIsolated {
                router.dispatch(event, accountID: accountID)
            }
        }
        // Bookmarks auto-join would re-enter every test account's stored rooms on
        // connect, polluting the smoke tests' event streams with unrelated joins.
        environment.bookmarksService.autoJoinEnabled = false

        let harness = TestHarness(environment: environment, router: router, tempDir: tempDir)
        do {
            try await body(harness)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    /// Creates and connects every account in `labels`, waiting for `.rosterLoaded`
    /// before returning. Cleanup for each successful account is registered immediately.
    func setUp(accounts labels: [String: TestCredentials.Credential]) async throws {
        // Sort by label so connect order is deterministic across runs.
        for (label, credential) in labels.sorted(by: { $0.key < $1.key }) {
            let accountID = try await environment.accountService.createAccount(jidString: credential.jid)

            // Refresh in-memory cache so service handlers (RosterService, BookmarksService,
            // AvatarService, OMEMOService, ChatService) can find the account when their
            // events fire — without this, `.connected`/`.rosterLoaded` are silently dropped.
            try await environment.accountService.loadAccounts()

            let (stream, continuation) = AsyncStream<XMPPEvent>.makeStream()
            router.register(accountID: accountID, continuation: continuation)

            do {
                try await environment.accountService.connect(accountID: accountID, password: credential.password)
            } catch {
                router.unregister(accountID: accountID)
                await environment.accountService.disconnect(accountID: accountID)
                try? await environment.accountService.deleteAccount(accountID)
                throw error
            }
            // Skip savePassword — writing live credentials to the temp
            // FileCredentialStore would leave plaintext secrets on disk.

            let connected = ConnectedAccount(accountID: accountID, eventStream: stream)
            accounts[label] = connected

            // Register cleanup before waiting for the roster so a hang here still
            // triggers full teardown via the LIFO chain.
            addCleanup { [environment] in
                await environment.accountService.disconnect(accountID: accountID)
            }

            _ = try await connected.waitForEvent(
                matching: { event in
                    if case .rosterLoaded = event { return true }
                    return false
                },
                timeout: TestTimeout.connect
            )
        }
    }

    /// Appends a cleanup action; actions run in reverse order during teardown.
    func addCleanup(_ action: @escaping @Sendable () async -> Void) {
        cleanupActions.append(action)
    }

    /// Polls until `accounts[label]`'s connection state becomes `.disconnected`.
    func waitUntilDisconnected(_ label: String, timeout: Duration = TestTimeout.event) async throws {
        let account = try #require(accounts[label])
        try await account.waitForCondition({
            if case .disconnected = self.environment.accountService.connectionStates[account.accountID] {
                return true
            }
            return false
        }, timeout: timeout)
    }

    /// Creates an ephemeral MUC room owned by `label` and registers destroy + leave cleanup.
    /// The room JID is randomized so concurrent test runs do not collide.
    func createEphemeralRoom(using label: String = "alice") async throws -> BareJID {
        let randomLocal = "inttest-\(UUID().uuidString.prefix(8))"
        let roomJID = try #require(BareJID.parse("\(randomLocal)@\(TestCredentials.mucService)"))
        let account = try #require(accounts[label])

        // ChatService.joinRoom silently returns if the client is missing, which would
        // make the subsequent waitForEvent hang until timeout instead of failing fast.
        guard case .connected = environment.accountService.connectionStates[account.accountID] else {
            throw TestHarnessError.notConnected(label: label)
        }

        try await environment.chatService.joinRoom(jid: roomJID, nickname: label, accountID: account.accountID)

        // Register cleanup before waiting for `.roomJoined` so a wait timeout or
        // stream error still destroys the server-side room instead of leaking it.
        let accountID = account.accountID
        addCleanup { [environment] in
            do {
                try await environment.chatService.destroyRoom(jidString: roomJID.description, reason: nil, accountID: accountID)
            } catch {
                // Owner-only destroy can fail if the account lost privilege; fall back
                // to leaving the room so the test occupant doesn't linger server-side.
                try? await environment.chatService.leaveRoom(jid: roomJID, accountID: accountID)
            }
        }

        let joinEvent = try await account.waitForEvent(
            matching: { event in
                if case let .roomJoined(joinedRoom, _, _) = event, joinedRoom == roomJID { return true }
                return false
            },
            timeout: TestTimeout.event
        )

        // Accept default config for newly created rooms so they are unlocked for
        // other occupants. Without this, the room stays in a "locked" state (MUC
        // status 201) and rejects join attempts from non-owners.
        if case let .roomJoined(_, _, isNewlyCreated) = joinEvent, isNewlyCreated {
            guard let client = environment.accountService.client(for: account.accountID),
                  let mucModule = await client.module(ofType: MUCModule.self) else {
                throw TestHarnessError.notConnected(label: label)
            }
            try await mucModule.acceptDefaultConfig(roomJID)
        }

        return roomJID
    }

    // MARK: - Teardown

    private func tearDown() async {
        // Run cleanups first so any action that awaits a server response can still
        // receive its event through the router. Finish continuations only after.
        for action in cleanupActions.reversed() {
            await runWithTimeout(action, timeout: .seconds(5))
        }
        cleanupActions.removeAll()

        router.finishAll()
        accounts.removeAll()

        do {
            try FileManager.default.removeItem(at: tempDir)
        } catch {
            log.warning("Failed to remove temp directory \(tempDir.path): \(error.localizedDescription)")
        }
    }

    /// Races an event predicate against a timeout on a raw `AsyncStream<XMPPEvent>`.
    /// Throws `TestHarnessError.timeout` if the event does not arrive in time.
    static func waitForRawEvent(
        in events: AsyncStream<XMPPEvent>,
        timeout: Duration = TestTimeout.event,
        matching predicate: @Sendable @escaping (XMPPEvent) -> Bool
    ) async throws {
        let found = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in events where predicate(event) {
                    return true
                }
                return false
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        if !found {
            throw TestHarnessError.timeout
        }
    }

    /// Runs `action` with a soft deadline: once `timeout` elapses the function
    /// logs a warning, but still waits for `action` to unwind via cooperative
    /// cancellation before returning. Callers must use cancellation-aware work.
    private func runWithTimeout(_ action: @escaping @Sendable () async -> Void, timeout: Duration) async {
        let timedOut: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await action()
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if timedOut {
            log.warning("Cleanup action timed out after \(timeout)")
        }
    }
}
