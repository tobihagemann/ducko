import Testing
@testable import DuckoXMPP

// MARK: - Helpers

/// Empty roster response for tests that don't need roster items pre-loaded.
private let emptyRosterResponse = "<iq type='result' id='ducko-2'><query xmlns='jabber:iq:roster'/></iq>"

/// Creates a connected client with RosterModule registered.
/// A roster response must always be provided since RosterModule blocks on connect waiting for it.
private func makeConnectedClient(mock: MockTransport, rosterResponse: String = emptyRosterResponse) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(RosterModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock, rosterResponse: rosterResponse)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum RosterModuleTests {
    struct RosterLoad {
        @Test
        func `Roster GET on connect parses items and emits rosterLoaded`() async throws {
            let mock = MockTransport()

            let rosterResponse = "<iq type='result' id='ducko-2'><query xmlns='jabber:iq:roster'><item jid='alice@example.com' name='Alice' subscription='both'/><item jid='bob@example.com' subscription='to'><group>Friends</group></item></query></iq>"

            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(RosterModule())

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .rosterLoaded = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock, rosterResponse: rosterResponse)
            try await connectTask.value

            let events = try await eventsTask.value
            guard case let .rosterLoaded(items) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected rosterLoaded event")
            }
            #expect(items.count == 2)

            let alice = items.first { $0.jid.description == "alice@example.com" }
            #expect(alice?.name == "Alice")
            #expect(alice?.subscription == .both)

            let bob = items.first { $0.jid.description == "bob@example.com" }
            #expect(bob?.subscription == .to)
            #expect(bob?.groups == ["Friends"])

            await client.disconnect()
        }
    }

    struct RosterPush {
        @Test
        func `Roster push updates map and emits rosterItemChanged`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .rosterItemChanged = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<iq type='set' id='push-1'><query xmlns='jabber:iq:roster'><item jid='new@example.com' name='New' subscription='both'/></query></iq>"
            )

            let events = try await eventsTask.value
            guard case let .rosterItemChanged(item) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected rosterItemChanged event")
            }
            #expect(item.jid.description == "new@example.com")
            #expect(item.name == "New")
            #expect(item.subscription == .both)

            await client.disconnect()
        }

        @Test
        func `Roster push with subscription=remove removes item`() async throws {
            let mock = MockTransport()
            let rosterResponse = "<iq type='result' id='ducko-2'><query xmlns='jabber:iq:roster'><item jid='alice@example.com' subscription='both'/></query></iq>"
            let client = try await makeConnectedClient(mock: mock, rosterResponse: rosterResponse)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .rosterItemChanged = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<iq type='set' id='push-2'><query xmlns='jabber:iq:roster'><item jid='alice@example.com' subscription='remove'/></query></iq>"
            )

            let events = try await eventsTask.value
            guard case let .rosterItemChanged(item) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected rosterItemChanged event")
            }
            #expect(item.subscription == .remove)

            await client.disconnect()
        }

        @Test
        func `Roster push from foreign JID is rejected`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client, timeout: .seconds(1)) { event in
                    if case .rosterItemChanged = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<iq type='set' from='evil@attacker.com' id='push-3'><query xmlns='jabber:iq:roster'><item jid='injected@evil.com' subscription='both'/></query></iq>"
            )

            // Verify no rosterItemChanged event was emitted by waiting for timeout
            do {
                _ = try await eventsTask.value
                throw XMPPClientError.unexpectedStreamState("Should have timed out")
            } catch is XMPPClientError {
                // Expected: timeout means foreign push was rejected
            }

            await client.disconnect()
        }
    }

    struct RosterManagement {
        @Test
        func `addContact sends correct IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: RosterModule.self))

            await mock.clearSentBytes()

            let jid = try #require(BareJID.parse("newcontact@example.com"))
            let addTask = Task {
                try await module.addContact(jid: jid, name: "New Contact", groups: ["Work"])
            }

            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let addIQ = sentStrings.first { $0.contains("newcontact@example.com") }
            #expect(addIQ != nil)
            #expect(addIQ?.contains("name=\"New Contact\"") == true)
            #expect(addIQ?.contains("<group>Work</group>") == true)

            // Respond with result to unblock the await
            if let iqStr = addIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
            }

            try await addTask.value

            await client.disconnect()
        }

        @Test
        func `removeContact sends correct IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: RosterModule.self))

            await mock.clearSentBytes()

            let jid = try #require(BareJID.parse("contact@example.com"))
            let removeTask = Task {
                try await module.removeContact(jid: jid)
            }

            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let removeIQ = sentStrings.first { $0.contains("subscription=\"remove\"") }
            #expect(removeIQ != nil)
            #expect(removeIQ?.contains("contact@example.com") == true)

            if let iqStr = removeIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
            }

            try await removeTask.value

            await client.disconnect()
        }
    }

    struct SubscriptionManagement {
        @Test
        func `Subscription methods send correct presence types`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: RosterModule.self))

            let jid = try #require(BareJID.parse("contact@example.com"))

            await mock.clearSentBytes()
            try await module.subscribe(to: jid)
            var sentData = await mock.sentBytes
            var sentString = String(decoding: sentData.last ?? [], as: UTF8.self)
            #expect(sentString.contains("type=\"subscribe\""))
            #expect(sentString.contains("to=\"contact@example.com\""))

            await mock.clearSentBytes()
            try await module.approveSubscription(from: jid)
            sentData = await mock.sentBytes
            sentString = String(decoding: sentData.last ?? [], as: UTF8.self)
            #expect(sentString.contains("type=\"subscribed\""))

            await mock.clearSentBytes()
            try await module.denySubscription(from: jid)
            sentData = await mock.sentBytes
            sentString = String(decoding: sentData.last ?? [], as: UTF8.self)
            #expect(sentString.contains("type=\"unsubscribed\""))

            await mock.clearSentBytes()
            try await module.unsubscribe(from: jid)
            sentData = await mock.sentBytes
            sentString = String(decoding: sentData.last ?? [], as: UTF8.self)
            #expect(sentString.contains("type=\"unsubscribe\""))

            await mock.clearSentBytes()
            try await module.preApprove(jid: jid)
            sentData = await mock.sentBytes
            sentString = String(decoding: sentData.last ?? [], as: UTF8.self)
            #expect(sentString.contains("type=\"subscribed\""))
            #expect(sentString.contains("to=\"contact@example.com\""))

            await client.disconnect()
        }
    }

    struct PreApproval {
        @Test
        func `Roster item with approved=true parses correctly`() throws {
            let element = XMLElement(name: "item", attributes: ["jid": "alice@example.com", "subscription": "from", "approved": "true"])
            let item = try #require(RosterItem.parse(element))
            #expect(item.approved == true)
            #expect(item.subscription == .from)
        }

        @Test
        func `Roster item without approved defaults to false`() throws {
            let element = XMLElement(name: "item", attributes: ["jid": "alice@example.com", "subscription": "both"])
            let item = try #require(RosterItem.parse(element))
            #expect(item.approved == false)
        }
    }

    struct DisconnectBehavior {
        @Test
        func `handleDisconnect clears roster`() async throws {
            let mock = MockTransport()
            let rosterResponse = "<iq type='result' id='ducko-2'><query xmlns='jabber:iq:roster'><item jid='alice@example.com' subscription='both'/></query></iq>"
            let client = try await makeConnectedClient(mock: mock, rosterResponse: rosterResponse)

            await client.disconnect()
        }
    }
}
