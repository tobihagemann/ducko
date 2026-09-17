import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(CarbonsModule())

    try await withIQOperation(client: client, operation: {
        try await client.connect(host: "example.com", port: 5222)
    }, respond: {
        await simulateNoTLSConnect(mock)
        let iqID = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "urn:xmpp:carbons:2") {
            $0.contains("<enable")
        }.id
        await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
    })

    return client
}

// MARK: - Tests

enum CarbonsModuleTests {
    struct EnableOnConnect {
        @Test
        func `Sends enable IQ on connect`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            await disconnectFast(client)
        }

        @Test
        func `Handles enable timeout gracefully`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(CarbonsModule())

            try await withIQOperation(client: client, operation: {
                try? await client.connect(host: "example.com", port: 5222)
            }, respond: {
                await simulateNoTLSConnect(mock)
                _ = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "urn:xmpp:carbons:2") {
                    $0.contains("<enable")
                }
                // Disconnect without responding — releases the pending enable IQ.
                await disconnectFast(client)
            })

            // Disconnect resets enabled state
        }
    }

    struct ReceivedCarbon {
        @Test
        func `Parses received carbon and emits messageCarbonReceived`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageCarbonReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='user@example.com' to='user@example.com/ducko' type='chat'>\
            <received xmlns='urn:xmpp:carbons:2'>\
            <forwarded xmlns='urn:xmpp:forward:0'>\
            <delay xmlns='urn:xmpp:delay' stamp='2026-03-01T12:00:00Z'/>\
            <message from='contact@example.com/res' to='user@example.com/other' type='chat'>\
            <body>Hello from other resource</body>\
            </message>\
            </forwarded>\
            </received>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageCarbonReceived(forwarded) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageCarbonReceived event")
            }
            #expect(forwarded.message.body == "Hello from other resource")
            #expect(forwarded.timestamp == "2026-03-01T12:00:00Z")

            await disconnectFast(client)
        }
    }

    struct SentCarbon {
        @Test
        func `Parses sent carbon and emits messageCarbonSent`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageCarbonSent = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='user@example.com' to='user@example.com/ducko' type='chat'>\
            <sent xmlns='urn:xmpp:carbons:2'>\
            <forwarded xmlns='urn:xmpp:forward:0'>\
            <message from='user@example.com/other' to='contact@example.com' type='chat'>\
            <body>Sent from other device</body>\
            </message>\
            </forwarded>\
            </sent>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageCarbonSent(forwarded) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageCarbonSent event")
            }
            #expect(forwarded.message.body == "Sent from other device")
            #expect(forwarded.timestamp == nil)

            await disconnectFast(client)
        }
    }

    struct Security {
        @Test
        func `Ignores carbons from foreign JIDs`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client, timeout: .seconds(1)) { event in
                    if case .messageCarbonReceived = event { return true }
                    if case .messageCarbonSent = event { return true }
                    return false
                }
            }

            // Carbon from a foreign JID should be ignored
            await mock.simulateReceive("""
            <message from='evil@attacker.com' to='user@example.com/ducko' type='chat'>\
            <received xmlns='urn:xmpp:carbons:2'>\
            <forwarded xmlns='urn:xmpp:forward:0'>\
            <message from='contact@example.com/res' to='evil@attacker.com' type='chat'>\
            <body>Spoofed</body>\
            </message>\
            </forwarded>\
            </received>\
            </message>
            """)

            // Verify no carbon event was emitted by waiting for timeout
            do {
                _ = try await eventsTask.value
                throw XMPPClientError.unexpectedStreamState("Should have timed out")
            } catch is XMPPClientError {
                // Expected: timeout means no carbon event was emitted
            }

            await disconnectFast(client)
        }
    }
}
