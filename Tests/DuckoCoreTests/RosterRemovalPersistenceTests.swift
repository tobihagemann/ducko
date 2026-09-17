import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
struct RosterRemovalPersistenceTests {
    @Test(arguments: [false, true])
    func `successful removal survives disconnect with a suspended roster push`(useContact: Bool) async throws {
        let store = MockPersistenceStore()
        let transport = MockTransport()
        let module = RosterModule()
        let accounts = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: MockXMPPClientFactory(transport: transport, modules: [module]))
        let roster = RosterService(store: store)
        roster.setAccountService(accounts)
        accounts.onRequestedDisconnect = { roster.purgeAccount($0) }
        let id = try await accounts.createAccount(jidString: "alice@example.com")
        let (_, connection) = try await driveMockConnect(accounts, accountID: id, transport: transport)
        let jid = try #require(BareJID.parse("bob@example.com"))
        await roster.handleEvent(.rosterLoaded([RosterItem(jid: jid, subscription: .both)]), accountID: id)
        let contact = try #require(roster.contact(jidString: jid.description, accountID: id))
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await store.installFetchContactsGate(entered: entered, release: release)
        let push = Task { await roster.handleEvent(.rosterItemChanged(RosterItem(jid: jid, subscription: .remove)), accountID: id) }
        let arrived = try await boundedOutcome { await entered.wait() }
        try #require(arrived != nil)
        await store.clearFetchContactsGate()
        await roster.handleEvent(.rosterVersionChanged("after-removal"), accountID: id)
        module.setUp(ModuleContext(sendStanza: { _ in }, sendIQ: { _ in nil }, emitEvent: { _ in }, generateID: { "remove" }, connectedJID: { nil }, domain: "example.com"))
        if useContact {
            try await roster.removeContact(contact, accountID: id)
        } else {
            try await roster.removeContact(jidString: jid.description, accountID: id)
        }
        await accounts.disconnect(accountID: id)
        await release.signal()
        await push.value
        _ = await connection.result
        #expect(try await store.fetchAccounts().first?.rosterVersion == "after-removal")
        let reloaded = RosterService(store: store)
        try await reloaded.loadContacts(for: id)
        #expect(reloaded.contact(jidString: jid.description, accountID: id) == nil)
        #expect(roster.groups.isEmpty)
    }

    @Test(arguments: [false, true])
    func `failed or disconnected removal leaves stored contacts intact`(disconnect: Bool) async throws {
        let store = MockPersistenceStore()
        let transport = MockTransport()
        let module = RosterModule()
        let accounts = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: MockXMPPClientFactory(transport: transport, modules: [module]))
        let roster = RosterService(store: store)
        roster.setAccountService(accounts)
        accounts.onRequestedDisconnect = { roster.purgeAccount($0) }
        let id = try await accounts.createAccount(jidString: "alice@example.com")
        let (_, connection) = try await driveMockConnect(accounts, accountID: id, transport: transport)
        let jid = try #require(BareJID.parse("bob@example.com"))
        await roster.handleEvent(.rosterLoaded([RosterItem(jid: jid, subscription: .both)]), accountID: id)
        module.setUp(ModuleContext(sendStanza: { _ in }, sendIQ: { _ in
            if disconnect {
                await accounts.disconnect(accountID: id)
                return nil
            }
            throw RemovalFailure.rejected
        }, emitEvent: { _ in }, generateID: { "remove" }, connectedJID: { nil }, domain: "example.com"))
        if disconnect {
            try await roster.removeContact(jidString: jid.description, accountID: id)
            #expect(roster.groups.isEmpty)
        } else {
            await #expect(throws: RemovalFailure.rejected) {
                try await roster.removeContact(jidString: jid.description, accountID: id)
            }
            #expect(roster.contact(jidString: jid.description, accountID: id) != nil)
        }
        #expect(try await store.fetchContacts(for: id).count == 1)
        await accounts.disconnect(accountID: id)
        _ = await connection.result
    }

    private enum RemovalFailure: Error { case rejected }
}
