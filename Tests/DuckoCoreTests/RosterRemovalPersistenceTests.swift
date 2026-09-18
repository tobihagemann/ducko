import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
struct RosterRemovalPersistenceTests {
    @Test(arguments: [false, true])
    func `successful removal waits for full saved readback behind a suspended push`(useContact: Bool) async throws {
        let fixture = RosterCommandFixture()
        try await fixture.connect()
        let contact = try #require(fixture.roster.contact(jidString: "bob@example.com", accountID: fixture.accountID))
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await fixture.store.installRosterApplyGate(entered: entered, release: release)
        await fixture.transport.simulateReceive("<iq type='set' id='push'><query xmlns='jabber:iq:roster' ver='push'><item jid='bob@example.com' subscription='remove'/></query></iq>")
        try #require(try await boundedOutcome { await entered.wait() } != nil)
        var completed = false
        let removal = Task {
            let outcome = try await useContact
                ? fixture.roster.removeContact(contact, accountID: fixture.accountID)
                : fixture.roster.removeContact(jidString: contact.jid.description, accountID: fixture.accountID)
            completed = true
            return outcome
        }
        let mutation = try await fixture.nextIQ(type: "set")
        await fixture.reply(to: mutation)
        let readback = try await fixture.nextIQ(type: "get")
        #expect(!readback.contains("ver="))
        #expect(!completed)
        await fixture.reply(to: readback, contents: "<query xmlns='jabber:iq:roster' ver='readback'/>")
        #expect(!completed)
        await release.signal()
        let outcome = try await removal.value
        #expect(outcome.isComplete)
        await fixture.close()
        #expect(try await fixture.store.fetchAccounts().first?.rosterVersion == "readback")
        #expect(try await fixture.store.fetchContacts(for: fixture.accountID).isEmpty)
        #expect(fixture.roster.groups.isEmpty)
    }

    @Test(arguments: [false, true])
    func `rejection and missing acknowledgement leave stored contacts intact`(disconnect: Bool) async throws {
        let fixture = RosterCommandFixture()
        try await fixture.connect()
        let removal = Task { try await fixture.roster.removeContact(jidString: "bob@example.com", accountID: fixture.accountID) }
        let mutation = try await fixture.nextIQ(type: "set")
        if disconnect {
            await fixture.accounts.disconnect(accountID: fixture.accountID)
        } else {
            await fixture.reply(to: mutation, contents: "<error type='cancel'><not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>", type: "error")
        }
        do {
            _ = try await removal.value
            Issue.record("Mutation without acknowledgement must throw")
        } catch let error as RosterCommandError {
            #expect(error.status == (disconnect ? .unconfirmed : .rejected))
            if !disconnect {
                #expect(error.detail == XMPPStanzaError(errorType: .cancel, condition: .notAllowed).displayText)
                #expect(!error.localizedDescription.contains("Request failed:"))
            }
        }
        #expect(try await fixture.store.fetchContacts(for: fixture.accountID).count == 1)
        await fixture.close()
    }
}
