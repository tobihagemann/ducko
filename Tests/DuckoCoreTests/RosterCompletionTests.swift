import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
struct RosterCompletionTests {
    @Test(arguments: ["timeout", "cancel", "replacement"])
    func `suspended command save cannot delay its terminal outcome or replace a new session`(ending: String) async throws {
        let clock = RosterTestClock()
        let fixture = RosterCommandFixture(clock: clock)
        try await fixture.connect()
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        let command = Task { try await fixture.roster.removeContact(jidString: "bob@example.com", accountID: fixture.accountID) }
        do {
            try await fixture.reply(to: fixture.nextIQ(type: "set"))
            let readback = try await fixture.nextIQ(type: "get")
            await fixture.store.installRosterApplyGate(entered: entered, release: release)
            await fixture.reply(to: readback, contents: "<query xmlns='jabber:iq:roster' ver='old-command'/>")
            try #require(try await boundedOutcome { await entered.wait() } != nil)
            switch ending {
            case "timeout": clock.advance(by: .seconds(6))
            case "cancel": command.cancel()
            case "replacement":
                let replacement = RosterServiceFixture(store: fixture.store, service: fixture.roster)
                let item = try RosterItem(jid: #require(BareJID.parse("carol@example.com")))
                await replacement.deliver(.snapshot([item]), accountID: fixture.accountID, version: "replacement")
            default: Issue.record("Unknown termination")
            }
            let settled = try await boundedOutcome { _ = try await command.value }
            try #require(settled).get()
            let outcome = try await command.value
            #expect(outcome.localStatus == .incomplete)
            #expect(outcome.subscriptionStatus == .notRequested)
            await release.signal()
            if ending == "replacement" {
                try await fixture.waitForApplication(version: "old-command")
                #expect(try await fixture.store.fetchAccounts().first?.rosterVersion == "replacement")
                #expect(fixture.roster.groups.flatMap(\.contacts).map(\.jid.description) == ["carol@example.com"])
            }
        } catch {
            command.cancel()
            await release.signal()
            await fixture.close()
            throw error
        }
        await fixture.close()
        #expect(clock.pendingCount == 0)
        #expect(fixture.roster.takePendingTasks().isEmpty)
    }

    @Test(arguments: ["timeout", "cancel", "disconnect", "no-query", "mismatch"])
    func `confirmed removal has a truthful partial outcome`(failure: String) async throws {
        let clock = RosterTestClock()
        let fixture = RosterCommandFixture(clock: clock)
        try await fixture.connect()
        let command = Task { try await fixture.roster.removeContact(jidString: "bob@example.com", accountID: fixture.accountID) }
        try await fixture.reply(to: fixture.nextIQ(type: "set"))
        let readback = try await fixture.nextIQ(type: "get")
        switch failure {
        case "timeout": clock.advance(by: .seconds(6))
        case "cancel": command.cancel()
        case "disconnect": await fixture.accounts.disconnect(accountID: fixture.accountID)
        case "no-query": await fixture.reply(to: readback)
        case "mismatch": await fixture.reply(to: readback, contents: "<query xmlns='jabber:iq:roster'><item jid='bob@example.com'/></query>")
        default: Issue.record("Unknown fixture")
        }
        let settled = try await boundedOutcome { _ = try await command.value }
        try #require(settled != nil)
        try settled?.get()
        let outcome = try await command.value
        #expect(!outcome.isComplete)
        #expect(outcome.localStatus == (failure == "mismatch" ? .different : .incomplete))
        #expect(outcome.subscriptionStatus == .notRequested)
        await fixture.close()
        #expect(clock.pendingCount == 0)
    }

    @Test
    func `finite list still accepts an identified snapshot after five seconds`() async throws {
        let clock = RosterTestClock()
        let fixture = RosterCommandFixture(clock: clock)
        try await fixture.connect()
        var completed = false
        let listing = Task {
            let result = try await fixture.roster.synchronizeRoster(accountID: fixture.accountID)
            completed = true
            return result
        }
        let readback = try await fixture.nextIQ(type: "get")
        clock.advance(by: .seconds(6))
        #expect(!completed)
        await fixture.reply(to: readback, contents: "<query xmlns='jabber:iq:roster' ver='empty'/>")
        #expect(try await listing.value.isEmpty)
        #expect(try await fixture.store.fetchAccounts().first?.rosterVersion == "empty")
        await fixture.close()
        #expect(clock.pendingCount == 0)
    }

    @Test
    func `matching push cannot finish mutation and later push cannot rewrite its readback outcome`() async throws {
        let fixture = RosterCommandFixture()
        try await fixture.connect()
        var completed = false
        let command = Task {
            let outcome = try await fixture.roster.removeContact(jidString: "bob@example.com", accountID: fixture.accountID)
            completed = true
            return outcome
        }
        try await fixture.reply(to: fixture.nextIQ(type: "set"))
        let readback = try await fixture.nextIQ(type: "get")
        await fixture.transport.simulateReceive("<iq type='set' id='removed'><query xmlns='jabber:iq:roster' ver='removed'><item jid='bob@example.com' subscription='remove'/></query></iq>")
        try await fixture.waitForApplication(version: "removed")
        #expect(!completed)
        let id = try #require(extractIQID(from: readback))
        await fixture.transport.simulateReceive("<iq type='result' id='\(id)'><query xmlns='jabber:iq:roster' ver='confirmed'/></iq><iq type='set' id='readded'><query xmlns='jabber:iq:roster' ver='readded'><item jid='bob@example.com'/></query></iq>")
        #expect(try await command.value.isComplete)
        try await fixture.waitForApplication(version: "readded")
        #expect(try await fixture.store.fetchContacts(for: fixture.accountID).count == 1)
        await fixture.close()
    }

    @Test
    func `listing waits for its full snapshot after cached baseline and delayed interim pushes`() async throws {
        let fixture = RosterCommandFixture()
        try await fixture.connect(cachedBaseline: true)
        let otherID = UUID()
        let otherJID = try #require(BareJID.parse("other@example.com"))
        try await fixture.store.upsertContact(Contact(id: UUID(), accountID: otherID, jid: otherJID, subscription: .both, groups: [], isBlocked: false, createdAt: Date()))
        var completed = false
        let listing = Task {
            let contacts = try await fixture.roster.synchronizeRoster(accountID: fixture.accountID)
            completed = true
            return contacts
        }
        let request = try await fixture.nextIQ(type: "get")
        #expect(!request.contains("ver="))
        await fixture.transport.simulateReceive("<iq type='set' id='interim'><query xmlns='jabber:iq:roster' ver='interim'><item jid='bob@example.com'/></query></iq>")
        try await fixture.waitForApplication(version: "interim")
        #expect(!completed)
        await fixture.reply(to: request, contents: "<query xmlns='jabber:iq:roster' ver='full'/>")
        #expect(try await listing.value.isEmpty)
        #expect(try await fixture.store.fetchContacts(for: otherID).count == 1)
        await fixture.close()
    }

    @Test
    func `subscription failure is independent of saved roster membership`() async throws {
        let fixture = RosterCommandFixture()
        try await fixture.connect(items: "")
        let command = Task { try await fixture.roster.addContact(jidString: "bob@example.com", name: "Bob", groups: [], accountID: fixture.accountID) }
        let mutation = try await fixture.nextIQ(type: "set")
        await fixture.transport.failNextSend(matching: "type=\"subscribe\"", error: XMPPClientError.notConnected)
        await fixture.reply(to: mutation)
        let readback = try await fixture.nextIQ(type: "get")
        await fixture.reply(to: readback, contents: "<query xmlns='jabber:iq:roster'><item jid='bob@example.com' name='Bob'/></query>")
        let outcome = try await command.value
        #expect(outcome.localStatus == .synchronized)
        #expect(outcome.subscriptionStatus == .incomplete)
        #expect(!outcome.isComplete)
        await fixture.close()
    }
}
