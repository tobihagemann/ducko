import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(ServiceDiscoveryModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

/// Clears the mock's sent buffer, injects an incoming stanza, waits for the
/// fire-and-forget response Task to flush, then returns the first reply that
/// contains both `id` and `result`. Returns `nil` on timeout.
private func awaitDiscoResponse(
    for requestID: String,
    request stanza: String,
    mock: MockTransport
) async -> String? {
    await mock.clearSentBytes()
    await mock.simulateReceive(stanza)
    try? await Task.sleep(for: .milliseconds(200))
    let sentStrings = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
    return sentStrings.first { $0.contains(requestID) && $0.contains("result") }
}

// MARK: - Tests

enum ServiceDiscoveryModuleTests {
    struct DiscoInfoResponse {
        @Test
        func `Responds to disco#info GET with identity and features`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let response = await awaitDiscoResponse(
                for: "disco-1",
                request: "<iq type='get' from='other@example.com/res' id='disco-1'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>",
                mock: mock
            )
            #expect(response != nil)
            #expect(response?.contains("category=\"client\"") == true)
            #expect(response?.contains("type=\"pc\"") == true)
            #expect(response?.contains("name=\"Ducko\"") == true)

            await client.disconnect()
        }

        @Test
        func `Response echoes queried node attribute`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // XEP-0115 §6.2 / XEP-0390 §4.2: strict-match caps verifiers
            // (e.g. Prosody mod_caps) expect the response to echo the exact
            // node attribute from the request.
            let capsNode = "http://jabber.org/protocol/caps#abc123"
            let response = await awaitDiscoResponse(
                for: "disco-2",
                request: "<iq type='get' from='other@example.com/res' id='disco-2'><query xmlns='http://jabber.org/protocol/disco#info' node='\(capsNode)'/></iq>",
                mock: mock
            )
            #expect(response != nil)
            #expect(response?.contains("node=\"\(capsNode)\"") == true)

            await client.disconnect()
        }

        @Test
        func `Response omits node attribute when query has none`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Negative case for the XEP-0115 echo: adding a node attribute
            // asymmetrically would also break strict-match verifiers.
            let response = await awaitDiscoResponse(
                for: "disco-3",
                request: "<iq type='get' from='other@example.com/res' id='disco-3'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>",
                mock: mock
            )
            #expect(response != nil)
            #expect(response?.contains("node=") == false)

            await client.disconnect()
        }
    }

    struct DiscoInfoQuery {
        @Test
        func `queryInfo parses identities and features`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ServiceDiscoveryModule.self))

            let queryTask = Task {
                try await module.queryInfo(for: .bare(BareJID.parse("server.example.com")!))
            }

            try? await Task.sleep(for: .milliseconds(100))

            // Find the IQ ID
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let discoIQ = sentStrings.last { $0.contains("disco#info") }

            if let iqStr = discoIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='server.example.com'>\
                <query xmlns='http://jabber.org/protocol/disco#info'>\
                <identity category='server' type='im' name='Example Server'/>\
                <feature var='http://jabber.org/protocol/disco#info'/>\
                <feature var='http://jabber.org/protocol/disco#items'/>\
                </query>\
                </iq>
                """)
            }

            let result = try await queryTask.value
            #expect(result.identities.count == 1)
            #expect(result.identities[0].category == "server")
            #expect(result.identities[0].type == "im")
            #expect(result.identities[0].name == "Example Server")
            #expect(result.features.count == 2)
            #expect(result.features.contains("http://jabber.org/protocol/disco#info"))
            #expect(result.features.contains("http://jabber.org/protocol/disco#items"))

            await client.disconnect()
        }
    }

    struct DiscoItemsQuery {
        @Test
        func `queryItems parses items`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ServiceDiscoveryModule.self))

            let queryTask = Task {
                try await module.queryItems(for: .bare(BareJID.parse("example.com")!))
            }

            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let discoIQ = sentStrings.last { $0.contains("disco#items") }

            if let iqStr = discoIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='example.com'>\
                <query xmlns='http://jabber.org/protocol/disco#items'>\
                <item jid='conference.example.com' name='Chat Rooms'/>\
                <item jid='pubsub.example.com' name='PubSub Service'/>\
                </query>\
                </iq>
                """)
            }

            let result = try await queryTask.value
            #expect(result.count == 2)
            #expect(result[0].jid.description == "conference.example.com")
            #expect(result[0].name == "Chat Rooms")
            #expect(result[1].jid.description == "pubsub.example.com")
            #expect(result[1].name == "PubSub Service")

            await client.disconnect()
        }
    }
}
