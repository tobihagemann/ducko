import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

/// Empty blocklist response for tests that don't need pre-loaded blocked JIDs.
private let emptyBlocklistResponse = "<iq type='result' id='{requestID}'><blocklist xmlns='urn:xmpp:blocking'/></iq>"

/// Creates a connected client with BlockingModule registered.
private func makeConnectedClient(mock: MockTransport, blocklistResponse: String = emptyBlocklistResponse) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(BlockingModule())

    try await withIQOperation(client: client, operation: {
        try await client.connect(host: "example.com", port: 5222)
    }, respond: {
        await simulateNoTLSConnect(mock)
        let iqID = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "urn:xmpp:blocking") {
            $0.contains("<blocklist")
        }.id
        await mock.simulateReceive(blocklistResponse.replacingOccurrences(of: "{requestID}", with: iqID))
    })

    return client
}

// MARK: - Tests

enum BlockingModuleTests {
    struct BlockListLoad {
        @Test
        func `Blocklist GET on connect parses JIDs and emits blockListLoaded`() async throws {
            let mock = MockTransport()

            let blocklistResponse = "<iq type='result' id='{requestID}'><blocklist xmlns='urn:xmpp:blocking'><item jid='spam@example.com'/><item jid='troll@example.com'/></blocklist></iq>"

            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(BlockingModule())

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .blockListLoaded = event { return true }
                    return false
                }
            }

            defer { eventsTask.cancel() }
            try await withIQOperation(client: client, operation: {
                try await client.connect(host: "example.com", port: 5222)
            }, respond: {
                await simulateNoTLSConnect(mock)
                let iqID = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "urn:xmpp:blocking") {
                    $0.contains("<blocklist")
                }.id
                await mock.simulateReceive(blocklistResponse.replacingOccurrences(of: "{requestID}", with: iqID))
            })

            let events = try await eventsTask.value
            guard case let .blockListLoaded(jids) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected blockListLoaded event")
            }
            #expect(jids.count == 2)

            let module = try #require(await client.module(ofType: BlockingModule.self))
            #expect(module.blockedJIDs.count == 2)

            await disconnectFast(client)
        }
    }

    struct BlockUnblock {
        @Test
        func `blockContact sends correct IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            await mock.clearSentBytes()

            let jid = try #require(BareJID.parse("spam@example.com"))
            try await withIQOperation(client: client, operation: {
                try await module.blockContact(jid: jid)
            }, respond: {
                let request = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "urn:xmpp:blocking") {
                    $0.contains("<block ") && $0.contains("spam@example.com")
                }
                #expect(request.xml.contains("<block xmlns=\"urn:xmpp:blocking\""))
                await mock.simulateReceive("<iq type='result' id='\(request.id)'/>")
            })
            await disconnectFast(client)
        }

        @Test
        func `unblockContact sends correct IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            await mock.clearSentBytes()

            let jid = try #require(BareJID.parse("spam@example.com"))
            try await withIQOperation(client: client, operation: {
                try await module.unblockContact(jid: jid)
            }, respond: {
                let request = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "urn:xmpp:blocking") {
                    $0.contains("<unblock ") && $0.contains("spam@example.com")
                }
                #expect(request.xml.contains("<unblock xmlns=\"urn:xmpp:blocking\""))
                await mock.simulateReceive("<iq type='result' id='\(request.id)'/>")
            })
            await disconnectFast(client)
        }
    }

    struct PushHandling {
        @Test
        func `Block push IQ updates blocked set and emits contactBlocked`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .contactBlocked = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<iq type='set' id='push-1'><block xmlns='urn:xmpp:blocking'><item jid='spammer@example.com'/></block></iq>"
            )

            let events = try await eventsTask.value
            guard case let .contactBlocked(jid) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected contactBlocked event")
            }
            #expect(jid.description == "spammer@example.com")
            #expect(module.blockedJIDs.contains(jid))

            await disconnectFast(client)
        }

        @Test
        func `Unblock push IQ updates blocked set and emits contactUnblocked`() async throws {
            let mock = MockTransport()

            let blocklistResponse = "<iq type='result' id='{requestID}'><blocklist xmlns='urn:xmpp:blocking'><item jid='spammer@example.com'/></blocklist></iq>"
            let client = try await makeConnectedClient(mock: mock, blocklistResponse: blocklistResponse)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            #expect(module.blockedJIDs.count == 1)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .contactUnblocked = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<iq type='set' id='push-2'><unblock xmlns='urn:xmpp:blocking'><item jid='spammer@example.com'/></unblock></iq>"
            )

            let events = try await eventsTask.value
            guard case let .contactUnblocked(jid) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected contactUnblocked event")
            }
            #expect(jid.description == "spammer@example.com")
            #expect(!module.blockedJIDs.contains(jid))

            await disconnectFast(client)
        }

        @Test
        func `Block push from foreign JID is rejected`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            await mock.simulateReceive(
                "<iq type='set' from='evil@attacker.com' id='push-3'><block xmlns='urn:xmpp:blocking'><item jid='injected@evil.com'/></block></iq>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            #expect(module.blockedJIDs.isEmpty)

            await disconnectFast(client)
        }
    }

    struct DisconnectBehavior {
        @Test
        func `handleDisconnect clears blocked JIDs`() async throws {
            let mock = MockTransport()

            let blocklistResponse = "<iq type='result' id='{requestID}'><blocklist xmlns='urn:xmpp:blocking'><item jid='spam@example.com'/></blocklist></iq>"
            let client = try await makeConnectedClient(mock: mock, blocklistResponse: blocklistResponse)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            #expect(!module.blockedJIDs.isEmpty)

            await disconnectFast(client)

            #expect(module.blockedJIDs.isEmpty)
        }
    }
}
