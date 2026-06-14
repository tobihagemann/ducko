import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct AccountIndicatorTests {
    private struct Setup {
        let accountService: AccountService
        let rosterService: RosterService
        let accountIDs: [UUID]
    }

    /// Builds an environment with the given accounts and rosters `peer` into each account whose index
    /// is listed in `peerInAccounts`.
    private static func makeSetup(
        accounts: [(jid: String, displayName: String?)],
        peer: String,
        peerInAccounts: [Int]
    ) async throws -> Setup {
        let store = MockPersistenceStore()
        var ids: [UUID] = []
        for (jid, displayName) in accounts {
            let id = UUID()
            ids.append(id)
            try await store.addAccount(Account(
                id: id, jid: #require(BareJID.parse(jid)), displayName: displayName,
                isEnabled: true, connectOnLaunch: false, createdAt: Date()
            ))
        }
        let peerJID = try #require(BareJID.parse(peer))
        for index in peerInAccounts {
            try await store.upsertContact(Contact(
                id: UUID(), accountID: ids[index], jid: peerJID,
                subscription: .both, groups: [], isBlocked: false, createdAt: Date()
            ))
        }
        let environment = AppEnvironment(store: store, transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())
        try await environment.accountService.loadAccounts()
        for index in peerInAccounts {
            try await environment.rosterService.loadContacts(for: ids[index])
        }
        return Setup(accountService: environment.accountService, rosterService: environment.rosterService, accountIDs: ids)
    }

    @Test func `no label when the peer is on a single account`() async throws {
        let setup = try await Self.makeSetup(
            accounts: [(jid: "bob@xmpp.example", displayName: nil)],
            peer: "alice@xmpp.example", peerInAccounts: [0]
        )
        #expect(AccountIndicator.label(
            for: setup.accountIDs[0], bareJID: "alice@xmpp.example",
            accountService: setup.accountService, rosterService: setup.rosterService
        ) == nil)
    }

    @Test func `localpart distinguishes accounts on the same domain`() async throws {
        let setup = try await Self.makeSetup(
            accounts: [(jid: "bob@xmpp.example", displayName: nil), (jid: "carol@xmpp.example", displayName: nil)],
            peer: "alice@xmpp.example", peerInAccounts: [0, 1]
        )
        #expect(AccountIndicator.label(
            for: setup.accountIDs[0], bareJID: "alice@xmpp.example",
            accountService: setup.accountService, rosterService: setup.rosterService
        ) == "bob")
        #expect(AccountIndicator.label(
            for: setup.accountIDs[1], bareJID: "alice@xmpp.example",
            accountService: setup.accountService, rosterService: setup.rosterService
        ) == "carol")
    }

    @Test func `full JID disambiguates when localparts collide across servers`() async throws {
        let setup = try await Self.makeSetup(
            accounts: [(jid: "bob@server-a.example", displayName: nil), (jid: "bob@server-b.example", displayName: nil)],
            peer: "alice@xmpp.example", peerInAccounts: [0, 1]
        )
        #expect(AccountIndicator.label(
            for: setup.accountIDs[0], bareJID: "alice@xmpp.example",
            accountService: setup.accountService, rosterService: setup.rosterService
        ) == "bob@server-a.example")
    }

    @Test func `display name wins over the JID-derived fallback`() async throws {
        let setup = try await Self.makeSetup(
            accounts: [(jid: "bob@xmpp.example", displayName: "Work"), (jid: "carol@xmpp.example", displayName: nil)],
            peer: "alice@xmpp.example", peerInAccounts: [0, 1]
        )
        #expect(AccountIndicator.label(
            for: setup.accountIDs[0], bareJID: "alice@xmpp.example",
            accountService: setup.accountService, rosterService: setup.rosterService
        ) == "Work")
    }

    // MARK: - tabLabel (the direct-1:1 gate)

    private func makeConversation(
        accountID: UUID, jid: String, type: Conversation.ConversationType, occupantNickname: String? = nil
    ) throws -> Conversation {
        try Conversation(
            id: UUID(), accountID: accountID, jid: #require(BareJID.parse(jid)), type: type,
            isPinned: false, isMuted: false, unreadCount: 0, occupantNickname: occupantNickname, createdAt: Date()
        )
    }

    @Test func `tabLabel returns the disambiguation label for a direct duplicated peer`() async throws {
        let setup = try await Self.makeSetup(
            accounts: [(jid: "bob@xmpp.example", displayName: nil), (jid: "carol@xmpp.example", displayName: nil)],
            peer: "alice@xmpp.example", peerInAccounts: [0, 1]
        )
        let key = ConversationKey(accountID: setup.accountIDs[0], jid: "alice@xmpp.example")
        let conversation = try makeConversation(accountID: setup.accountIDs[0], jid: "alice@xmpp.example", type: .chat)
        #expect(AccountIndicator.tabLabel(
            for: key, conversation: conversation,
            accountService: setup.accountService, rosterService: setup.rosterService
        ) == "bob")
    }

    @Test func `tabLabel returns nil for a groupchat tab`() async throws {
        let setup = try await Self.makeSetup(
            accounts: [(jid: "bob@xmpp.example", displayName: nil), (jid: "carol@xmpp.example", displayName: nil)],
            peer: "alice@xmpp.example", peerInAccounts: [0, 1]
        )
        let key = ConversationKey(accountID: setup.accountIDs[0], jid: "alice@xmpp.example")
        let room = try makeConversation(accountID: setup.accountIDs[0], jid: "alice@xmpp.example", type: .groupchat)
        #expect(AccountIndicator.tabLabel(
            for: key, conversation: room,
            accountService: setup.accountService, rosterService: setup.rosterService
        ) == nil)
    }

    @Test func `tabLabel returns nil for a MUC private-message tab`() async throws {
        let setup = try await Self.makeSetup(
            accounts: [(jid: "bob@xmpp.example", displayName: nil), (jid: "carol@xmpp.example", displayName: nil)],
            peer: "alice@xmpp.example", peerInAccounts: [0, 1]
        )
        let key = ConversationKey(accountID: setup.accountIDs[0], jid: "alice@xmpp.example")
        let pm = try makeConversation(accountID: setup.accountIDs[0], jid: "alice@xmpp.example", type: .chat, occupantNickname: "nick")
        #expect(AccountIndicator.tabLabel(
            for: key, conversation: pm,
            accountService: setup.accountService, rosterService: setup.rosterService
        ) == nil)
    }

    @Test func `tabLabel returns nil when the key has no account`() async throws {
        let setup = try await Self.makeSetup(
            accounts: [(jid: "bob@xmpp.example", displayName: nil), (jid: "carol@xmpp.example", displayName: nil)],
            peer: "alice@xmpp.example", peerInAccounts: [0, 1]
        )
        let key = ConversationKey(accountID: nil, jid: "alice@xmpp.example")
        #expect(AccountIndicator.tabLabel(
            for: key, conversation: nil,
            accountService: setup.accountService, rosterService: setup.rosterService
        ) == nil)
    }

    // MARK: - qualified (the accessibility-identifier qualifier)

    @Test func `qualified returns the base id when not qualifying`() async throws {
        let setup = try await Self.makeSetup(
            accounts: [(jid: "bob@xmpp.example", displayName: nil)], peer: "alice@xmpp.example", peerInAccounts: [0]
        )
        #expect(AccountIndicator.qualified(
            "alice@xmpp.example", accountID: setup.accountIDs[0], qualify: false, accountService: setup.accountService
        ) == "alice@xmpp.example")
    }

    @Test func `qualified appends the account JID when qualifying`() async throws {
        let setup = try await Self.makeSetup(
            accounts: [(jid: "bob@xmpp.example", displayName: nil)], peer: "alice@xmpp.example", peerInAccounts: [0]
        )
        #expect(AccountIndicator.qualified(
            "alice@xmpp.example", accountID: setup.accountIDs[0], qualify: true, accountService: setup.accountService
        ) == "alice@xmpp.example|bob@xmpp.example")
    }

    @Test func `qualified returns the base id when the account cannot be resolved`() async throws {
        let setup = try await Self.makeSetup(
            accounts: [(jid: "bob@xmpp.example", displayName: nil)], peer: "alice@xmpp.example", peerInAccounts: [0]
        )
        #expect(AccountIndicator.qualified(
            "alice@xmpp.example", accountID: UUID(), qualify: true, accountService: setup.accountService
        ) == "alice@xmpp.example")
    }
}
