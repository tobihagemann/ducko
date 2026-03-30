import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private struct TestError: Error {}

private let testJIDString = "alice@example.com"
private let testJID = BareJID(localPart: "alice", domainPart: "example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

private func makeCredentials() -> MockCredentialStore {
    MockCredentialStore()
}

@MainActor
private func makeAccountService(
    store: MockPersistenceStore,
    credentials: MockCredentialStore = makeCredentials(),
    clientFactory: any XMPPClientFactory = DefaultXMPPClientFactory()
) -> AccountService {
    AccountService(store: store, credentialStore: credentials, clientFactory: clientFactory)
}

private func makeAccount(id: UUID = UUID(), jid: BareJID = testJID) -> Account {
    Account(id: id, jid: jid, isEnabled: true, connectOnLaunch: false, createdAt: Date())
}

private func makeConversation(accountID: UUID? = nil, jid: BareJID, importSourceJID: String? = nil) -> Conversation {
    Conversation(
        id: UUID(),
        accountID: accountID,
        importSourceJID: importSourceJID,
        jid: jid,
        type: .chat,
        isPinned: false,
        isMuted: false,
        unreadCount: 0,
        createdAt: Date()
    )
}

// MARK: - Tests

enum AccountServiceTests {
    struct CreateAccount {
        @Test
        @MainActor
        func `createAccount with valid JID persists account`() async throws {
            let store = makeStore()
            let service = makeAccountService(store: store)

            let accountID = try await service.createAccount(jidString: testJIDString)

            let accounts = try await store.fetchAccounts()
            #expect(accounts.count == 1)
            #expect(accounts[0].id == accountID)
            #expect(accounts[0].jid == testJID)
            #expect(accounts[0].isEnabled == true)
            #expect(accounts[0].requireTLS == true)
        }

        @Test
        @MainActor
        func `createAccount with invalid JID throws invalidJID`() async throws {
            let store = makeStore()
            let service = makeAccountService(store: store)

            await #expect(throws: AccountService.AccountServiceError.self) {
                _ = try await service.createAccount(jidString: "")
            }

            let accounts = try await store.fetchAccounts()
            #expect(accounts.isEmpty)
        }

        @Test
        @MainActor
        func `createAccount auto-links imported conversations`() async throws {
            let store = makeStore()
            let contactJID = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let conv = makeConversation(jid: contactJID, importSourceJID: testJIDString)
            await store.addConversation(conv)

            let service = makeAccountService(store: store)
            let accountID = try await service.createAccount(jidString: testJIDString)

            let linked = try await store.fetchConversations(for: accountID)
            #expect(linked.count == 1)
            #expect(linked[0].accountID == accountID)
            #expect(linked[0].importSourceJID == nil)
        }

        @Test
        @MainActor
        func `createAccount with no matching imports links nothing`() async throws {
            let store = makeStore()
            let otherJID = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let conv = makeConversation(jid: otherJID, importSourceJID: "other@example.com")
            await store.addConversation(conv)

            let service = makeAccountService(store: store)
            let accountID = try await service.createAccount(jidString: testJIDString)

            let linked = try await store.fetchConversations(for: accountID)
            #expect(linked.isEmpty)

            // Verify the original conversation is unchanged
            let all = try await store.fetchAllConversations()
            #expect(all.count == 1)
            #expect(all[0].importSourceJID == "other@example.com")
        }

        @Test
        @MainActor
        func `createAccount passes optional fields to store`() async throws {
            let store = makeStore()
            let service = makeAccountService(store: store)

            _ = try await service.createAccount(
                jidString: testJIDString,
                displayName: "Alice",
                host: "xmpp.example.com",
                port: 5223,
                resource: "phone",
                requireTLS: false,
                connectOnLaunch: true,
                importedFrom: "Adium"
            )

            let accounts = try await store.fetchAccounts()
            #expect(accounts.count == 1)
            #expect(accounts[0].displayName == "Alice")
            #expect(accounts[0].host == "xmpp.example.com")
            #expect(accounts[0].port == 5223)
            #expect(accounts[0].resource == "phone")
            #expect(accounts[0].requireTLS == false)
            #expect(accounts[0].connectOnLaunch == true)
            #expect(accounts[0].importedFrom == "Adium")
        }
    }

    struct LoadAccounts {
        @Test
        @MainActor
        func `loadAccounts populates accounts and connectionStates`() async throws {
            let store = makeStore()
            let account = makeAccount()
            await store.addAccount(account)

            let service = makeAccountService(store: store)
            try await service.loadAccounts()

            #expect(service.accounts.count == 1)
            #expect(service.accounts[0].id == account.id)
            if case .disconnected = service.connectionStates[account.id] {
                // Expected
            } else {
                Issue.record("Expected .disconnected, got \(String(describing: service.connectionStates[account.id]))")
            }
        }
    }

    struct DeleteAccount {
        @Test
        @MainActor
        func `deleteAccount removes from store and deletes password`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let account = makeAccount()
            await store.addAccount(account)
            credentials.savePassword("secret", for: account.jid.description)

            let service = makeAccountService(store: store, credentials: credentials)
            try await service.loadAccounts()
            #expect(service.accounts.count == 1)

            try await service.deleteAccount(account.id)

            #expect(service.accounts.isEmpty)
            let storedAccounts = try await store.fetchAccounts()
            #expect(storedAccounts.isEmpty)
            #expect(credentials.loadPassword(for: account.jid.description) == nil)
        }
    }

    struct CredentialManagement {
        @Test
        @MainActor
        func `connect without stored password throws noStoredPassword`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let account = makeAccount()
            await store.addAccount(account)

            let service = makeAccountService(store: store, credentials: credentials)
            try await service.loadAccounts()

            await #expect(throws: AccountService.AccountServiceError.self) {
                try await service.connect(accountID: account.id)
            }
        }
    }

    struct CreateAndConnect {
        @Test
        @MainActor
        func `rollback on connection failure deletes account and unlinks conversations`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let contactJID = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let conv = makeConversation(jid: contactJID, importSourceJID: testJIDString)
            await store.addConversation(conv)

            let transport = MockTransport(connectError: TestError())
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)

            await #expect(throws: TestError.self) {
                _ = try await service.createAndConnect(
                    jidString: testJIDString, password: "secret",
                    host: "example.com", port: 5222
                )
            }

            let accounts = try await store.fetchAccounts()
            #expect(accounts.isEmpty)

            let all = try await store.fetchAllConversations()
            #expect(all.count == 1)
            #expect(all[0].accountID == nil)
            #expect(all[0].importSourceJID == testJIDString)

            #expect(credentials.loadPassword(for: testJIDString) == nil)
        }

        @Test
        @MainActor
        func `success saves password and reloads accounts`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)

            let connectTask = Task { @MainActor in
                try await service.createAndConnect(
                    jidString: testJIDString, password: "secret",
                    host: "example.com", port: 5222
                )
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connectTask.value

            #expect(credentials.loadPassword(for: testJIDString) == "secret")

            let accounts = try await store.fetchAccounts()
            #expect(accounts.count == 1)
            #expect(accounts[0].id == accountID)
        }

        @Test
        @MainActor
        func `afterConnect failure triggers rollback with contact deletion`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let contactJID = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let conv = makeConversation(jid: contactJID, importSourceJID: testJIDString)
            await store.addConversation(conv)

            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)

            let connectTask = Task { @MainActor in
                try await service.createAndConnect(
                    jidString: testJIDString, password: "secret",
                    host: "example.com", port: 5222,
                    afterConnect: { accountID in
                        let contact = Contact(
                            id: UUID(), accountID: accountID, jid: contactJID,
                            subscription: .both, groups: [], isBlocked: false, createdAt: Date()
                        )
                        try await store.upsertContact(contact)
                        throw TestError()
                    }
                )
            }
            await simulateNoTLSConnect(transport)

            await #expect(throws: TestError.self) {
                _ = try await connectTask.value
            }

            let accounts = try await store.fetchAccounts()
            #expect(accounts.isEmpty)

            let contacts = await store.contacts
            #expect(contacts.isEmpty)

            let all = try await store.fetchAllConversations()
            #expect(all.count == 1)
            #expect(all[0].accountID == nil)
            #expect(all[0].importSourceJID == testJIDString)

            #expect(credentials.loadPassword(for: testJIDString) == nil)
        }
    }

    struct IsAuthenticationError {
        @Test
        func `returns true for authenticationFailed`() {
            let error: any Error = XMPPClientError.authenticationFailed("not-authorized")
            #expect(AccountService.isAuthenticationError(error))
        }

        @Test
        func `returns false for other XMPPClientError cases`() {
            #expect(!AccountService.isAuthenticationError(XMPPClientError.notConnected))
            #expect(!AccountService.isAuthenticationError(XMPPClientError.timeout))
            #expect(!AccountService.isAuthenticationError(XMPPClientError.tlsRequired))
        }

        @Test
        func `returns false for unrelated errors`() {
            #expect(!AccountService.isAuthenticationError(TestError()))
        }
    }

    struct SavePassword {
        @Test
        @MainActor
        func `savePassword persists to credential store`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let transport = MockTransport(connectError: TestError())
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)

            let accountID = try await service.createAccount(jidString: testJIDString)
            try await service.loadAccounts()

            // connect sets passwords[accountID] before performConnect throws
            do {
                try await service.connect(accountID: accountID, password: "secret")
            } catch is TestError {}

            await service.savePassword(accountID: accountID)

            #expect(credentials.loadPassword(for: testJIDString) == "secret")
        }
    }
}
