import AppKit
import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct RosterOutcomeTests {
    @Test(arguments: [false, true])
    func `both removal owners preserve a partial notice with account and contact context`(infoWindow: Bool) async throws {
        let fixture = try await RosterUIFixture.connected()
        let contact = try #require(fixture.environment.rosterService.contact(jidString: "bob@example.com", accountID: fixture.accountID))
        let noticeArrived = AsyncSemaphore()
        var notice: String?
        var noticeAccount: UUID?
        let state = ContactInfoWindowState(ref: ContactInfoRef(accountID: fixture.accountID, jid: "bob@example.com"), environment: fixture.environment)
        await state.load()
        let action: Task<Void, Never>?
        if infoWindow {
            action = Task { await state.remove() }
        } else {
            action = nil
            let builder = ContactListMenuBuilder(openChat: OpenChatAction { _, _ in }, openWindow: nil, transcriptScope: nil, presentSheet: { _ in }, presentNotice: { text, account in
                notice = text
                noticeAccount = account
                Task { await noticeArrived.signal() }
            }, target: NSView(), action: Selector(("unused:")))
            let menu = try #require(builder.menu(for: .contact(sectionName: "Ungrouped", contact: contact), environment: fixture.environment))
            let item = try #require(menu.items.first { $0.accessibilityIdentifier() == "contact-context-remove" })
            try #require(item.representedObject as? MenuCommand).run()
        }
        let mutation = try await fixture.next("type=\"set\"")
        await fixture.reply(to: mutation)
        let readback = try await fixture.next("type=\"get\"")
        // The contact can disappear while the confirmed command's readback fails.
        await fixture.transport.simulateReceive("<iq type='set' id='removed'><query xmlns='jabber:iq:roster'><item jid='bob@example.com' subscription='remove'/></query></iq>")
        try await fixture.waitUntil { fixture.environment.rosterService.contact(jidString: "bob@example.com", accountID: fixture.accountID) == nil }
        await fixture.reply(to: readback)
        if let action {
            await action.value
            #expect(state.contact == nil)
            #expect(!state.isRemoving)
            #expect(state.rosterNotice?.contains("alice@example.com") == true)
            #expect(state.rosterNotice?.contains("bob@example.com") == true)
            #expect(state.rosterNotice?.contains("sync") == true)
        } else {
            try #require(try await boundedOutcome { await noticeArrived.wait() } != nil)
            #expect(notice?.contains("bob@example.com") == true)
            #expect(noticeAccount == fixture.accountID)
        }
        await fixture.environment.accountService.disconnect(accountID: fixture.accountID)
        await fixture.environment.shutdown(within: .seconds(2))
    }
}

@MainActor
private final class RosterUIFixture {
    let transport: MockTransport
    let environment: AppEnvironment
    let accountID: UUID
    private var seen: Set<String> = []

    private init(transport: MockTransport, environment: AppEnvironment, accountID: UUID) {
        self.transport = transport
        self.environment = environment
        self.accountID = accountID
    }

    static func connected() async throws -> RosterUIFixture {
        let transport = MockTransport()
        let environment = AppEnvironment(store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore(), clientFactory: RosterUIFactory(transport: transport))
        let id = try await environment.accountService.createAccount(jidString: "alice@example.com")
        let fixture = RosterUIFixture(transport: transport, environment: environment, accountID: id)
        let connection = Task { try await environment.accountService.connect(accountID: id, password: "local-fixture") }
        try await fixture.exchange("<stream:stream", testServerStreamOpen + testFeaturesNoTLS)
        try await fixture.exchange("<auth", "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        try await fixture.exchange("<stream:stream", testServerStreamOpen + testFeaturesBind)
        let bind = try await fixture.next("urn:ietf:params:xml:ns:xmpp-bind")
        await fixture.reply(to: bind, contents: "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>alice@example.com/fixture</jid></bind>")
        let initial = try await fixture.next("jabber:iq:roster")
        await fixture.reply(to: initial, contents: "<query xmlns='jabber:iq:roster'><item jid='bob@example.com'/></query>")
        try await connection.value
        try await fixture.waitUntil { environment.rosterService.contact(jidString: "bob@example.com", accountID: id) != nil }
        await transport.clearSentBytes()
        return fixture
    }

    func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let result = try await boundedOutcome { @MainActor in
            while !predicate() {
                try Task.checkCancellation(); await Task.yield()
            }
        }
        try #require(result != nil)
        try result?.get()
    }

    func next(_ fragment: String) async throws -> String {
        let seen = seen
        let task = Task { [transport] in await transport.waitForSent(matching: { $0.contains(fragment) && !seen.contains(extractIQID(from: $0) ?? "") }) }
        let result = try await boundedOutcome { _ = await task.value }
        guard result != nil else { task.cancel(); throw CancellationError() }
        let stanza = try #require(await task.value)
        if let id = extractIQID(from: stanza) { self.seen.insert(id) }
        return stanza
    }

    func exchange(_ fragment: String, _ reply: String) async throws {
        _ = try await next(fragment)
        await transport.clearSentBytes()
        await transport.simulateReceive(reply)
    }

    func reply(to stanza: String, contents: String = "") async {
        guard let id = extractIQID(from: stanza) else { Issue.record("Missing id"); return }
        await transport.simulateReceive("<iq type='result' id='\(id)'>\(contents)</iq>")
    }
}

private struct RosterUIFactory: XMPPClientFactory {
    let transport: MockTransport
    func makeClient(account: Account, password: String, previousSMState: SMResumeState?, requireTLSOverride: Bool?, omemoService: OMEMOService?) async -> (XMPPClient, StreamManagementModule) {
        var builder = XMPPClientBuilder(domain: "example.com", username: "alice", password: password)
        builder.withTransport(transport)
        builder.withRequireTLS(false)
        let sm = StreamManagementModule()
        builder.withModule(sm)
        builder.withInterceptor(sm)
        builder.withModule(RosterModule())
        return await (builder.build(), sm)
    }
}
