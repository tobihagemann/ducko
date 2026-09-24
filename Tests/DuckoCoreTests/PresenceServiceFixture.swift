import DuckoTestSupport
import Foundation
@testable import DuckoCore
@testable import DuckoXMPP

struct MockIdleTimeSource: IdleTimeSource {
    var idleSeconds: TimeInterval

    func secondsSinceLastUserInput() -> TimeInterval {
        idleSeconds
    }
}

@MainActor
func makePresenceService(idleTimeSource: any IdleTimeSource = MockIdleTimeSource(idleSeconds: 0)) -> PresenceService {
    PresenceService(idleTimeSource: idleTimeSource)
}

/// Alice and Bob on one wired `AccountService`/`PresenceService` pair, before either connects.
@MainActor
struct TwoAccountServices {
    let store: MockPersistenceStore
    let accountService: AccountService
    let presenceService: PresenceService
    let aliceTransport: MockTransport
    let bobTransport: MockTransport
    let aliceID: UUID
    let bobID: UUID
}

@MainActor
func makeTwoAccountServices() async throws -> TwoAccountServices {
    let store = MockPersistenceStore()
    let aliceTransport = MockTransport()
    let bobTransport = MockTransport()
    let factory = MockXMPPClientFactory(
        transportForAccount: { $0.jid.localPart == "alice" ? aliceTransport : bobTransport },
        modulesForAccount: { _ in [PresenceModule(), CapsModule()] }
    )
    let accountService = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: factory)
    let presenceService = PresenceService()
    presenceService.setAccountService(accountService)
    accountService.onRequestedDisconnect = { [weak presenceService] accountID in
        presenceService?.purgeAccount(accountID)
    }

    let aliceID = try await accountService.createAccount(jidString: "alice@example.com", host: "example.com", port: 5222)
    let bobID = try await accountService.createAccount(jidString: "bob@example.com", host: "example.com", port: 5222)
    return TwoAccountServices(
        store: store,
        accountService: accountService,
        presenceService: presenceService,
        aliceTransport: aliceTransport,
        bobTransport: bobTransport,
        aliceID: aliceID,
        bobID: bobID
    )
}

@MainActor
struct TwoConnectedAccountsFixture {
    let store: MockPersistenceStore
    let accountService: AccountService
    let presenceService: PresenceService
    let aliceTransport: MockTransport
    let bobTransport: MockTransport
    let aliceID: UUID
    let bobID: UUID
    let aliceTask: Task<Void, any Error>
    let bobTask: Task<Void, any Error>

    init(_ services: TwoAccountServices, aliceTask: Task<Void, any Error>, bobTask: Task<Void, any Error>) {
        self.store = services.store
        self.accountService = services.accountService
        self.presenceService = services.presenceService
        self.aliceTransport = services.aliceTransport
        self.bobTransport = services.bobTransport
        self.aliceID = services.aliceID
        self.bobID = services.bobID
        self.aliceTask = aliceTask
        self.bobTask = bobTask
    }

    func teardown() async {
        aliceTask.cancel()
        bobTask.cancel()
        await accountService.disconnect(accountID: aliceID)
        await accountService.disconnect(accountID: bobID)
    }
}

@MainActor
func makeTwoConnectedAccounts() async throws -> TwoConnectedAccountsFixture {
    let services = try await makeTwoAccountServices()
    let (_, aliceTask) = try await driveMockConnect(
        services.accountService, accountID: services.aliceID, transport: services.aliceTransport, awaitInitialPresence: true
    )
    let (_, bobTask) = try await driveMockConnect(
        services.accountService, accountID: services.bobID, transport: services.bobTransport, awaitInitialPresence: true
    )
    return TwoConnectedAccountsFixture(services, aliceTask: aliceTask, bobTask: bobTask)
}
