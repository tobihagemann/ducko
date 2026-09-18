import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
struct RosterRecoveryTests {
    @Test
    func `failed delta fences later work and one recovery repairs the cache`() async throws {
        let fixture = RosterCommandFixture()
        try await fixture.connect()
        await fixture.store.failNextRosterApplications()
        await fixture.transport.simulateReceive("<iq type='set' id='failed'><query xmlns='jabber:iq:roster' ver='failed'><item jid='bob@example.com' subscription='remove'/></query></iq><iq type='set' id='later'><query xmlns='jabber:iq:roster' ver='later'><item jid='carol@example.com'/></query></iq>")
        let recovery = try await fixture.nextIQ(type: "get")
        #expect(!recovery.contains("ver="))
        #expect(try await fixture.store.fetchAccounts().first?.rosterVersion == "initial")
        #expect(try await fixture.store.fetchContacts(for: fixture.accountID).map(\.jid.description) == ["bob@example.com"])
        await fixture.reply(to: recovery, contents: "<query xmlns='jabber:iq:roster' ver='repaired'><item jid='carol@example.com'/></query>")
        try await fixture.waitForApplication(version: "repaired")
        #expect(try await fixture.store.fetchAccounts().first?.rosterVersion == "repaired")
        #expect(try await fixture.store.fetchContacts(for: fixture.accountID).map(\.jid.description) == ["carol@example.com"])
        let attempted = await fixture.store.rosterMutations.map(\.version)
        #expect(!attempted.contains("later"))

        await fixture.store.failNextRosterApplications()
        await fixture.transport.simulateReceive("<iq type='set' id='again'><query xmlns='jabber:iq:roster' ver='again'><item jid='carol@example.com' subscription='remove'/></query></iq>")
        try await fixture.waitForApplication(version: "again")
        await #expect(throws: RosterSynchronization.Failure.degraded) {
            _ = try await fixture.roster.synchronizeRoster(accountID: fixture.accountID)
        }
        let gets = await fixture.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter { $0.contains("type=\"get\"") && $0.contains("jabber:iq:roster") }
        #expect(gets.count == 1)
        #expect(try await fixture.store.fetchAccounts().first?.rosterVersion == "repaired")
        await fixture.close()
    }

    @Test(arguments: [false, true])
    func `recovery query or save failure degrades without a loop`(failSave: Bool) async throws {
        let fixture = RosterCommandFixture()
        try await fixture.connect()
        await fixture.store.failNextRosterApplications(failSave ? 2 : 1)
        await fixture.transport.simulateReceive("<iq type='set' id='failed'><query xmlns='jabber:iq:roster' ver='failed'><item jid='bob@example.com' subscription='remove'/></query></iq>")
        let recovery = try await fixture.nextIQ(type: "get")
        let synchronization = Task { try await fixture.roster.synchronizeRoster(accountID: fixture.accountID) }
        if failSave {
            await fixture.reply(to: recovery, contents: "<query xmlns='jabber:iq:roster' ver='recovery'/>")
        } else {
            await fixture.reply(to: recovery, contents: "<error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>", type: "error")
        }
        await #expect(throws: RosterSynchronization.Failure.degraded) { _ = try await synchronization.value }
        #expect(try await fixture.store.fetchAccounts().first?.rosterVersion == "initial")
        let gets = await fixture.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter { $0.contains("type=\"get\"") && $0.contains("jabber:iq:roster") }
        #expect(gets.count == 1)
        await fixture.close()
    }

    @Test
    func `initial query failure discards fenced pushes and fails synchronization promptly`() async throws {
        let store = MockPersistenceStore()
        let fixture = RosterServiceFixture(store: store)
        let id = UUID()
        try await fixture.prepare(accountID: id)
        let item = try RosterItem(jid: #require(BareJID.parse("bob@example.com")))
        fixture.service.receiveRosterEvent(.rosterUpdated(RosterUpdate(receipt: 1, origin: .push, contents: .delta(item), version: "push")), accountID: id)
        await fixture.service.receiveRosterEvent(.rosterUpdated(RosterUpdate(receipt: 2, origin: .initial, contents: .initialQueryFailed, version: nil)), accountID: id)?.value
        await #expect(throws: RosterSynchronization.Failure.degraded) { _ = try await fixture.service.synchronizeRoster(accountID: id) }
        #expect(await store.rosterMutations.isEmpty)
        #expect(try await store.fetchContacts(for: id).isEmpty)
        fixture.service.purgeAccount(id)
    }
}
