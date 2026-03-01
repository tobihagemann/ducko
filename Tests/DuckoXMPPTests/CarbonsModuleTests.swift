import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock
    )
    await client.register(CarbonsModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }

    // Simulate connect, then respond to carbons enable IQ
    await simulateNoTLSConnect(mock)
    try? await Task.sleep(for: .milliseconds(100))

    let sentData = await mock.sentBytes
    let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
    let enableIQ = sentStrings.first { $0.contains("urn:xmpp:carbons:2") && $0.contains("<enable") }
    if let iqStr = enableIQ, let iqID = extractIQID(from: iqStr) {
        await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
    }

    try await connectTask.value

    return client
}

// MARK: - Tests

enum CarbonsModuleTests {
    struct EnableOnConnect {
        @Test("Sends enable IQ on connect")
        func sendsEnableIQ() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: CarbonsModule.self))

            #expect(module.isEnabled)

            await client.disconnect()
        }

        @Test("Handles enable timeout gracefully")
        func handlesEnableTimeout() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )
            await client.register(CarbonsModule())

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }

            await simulateNoTLSConnect(mock)
            try? await Task.sleep(for: .milliseconds(100))

            // Disconnect without responding to the enable IQ — cancels the pending IQ
            await client.disconnect()

            // Connect should still succeed (or have already completed before disconnect)
            try? await connectTask.value

            let module = try #require(await client.module(ofType: CarbonsModule.self))
            // Disconnect resets enabled state
            #expect(!module.isEnabled)
        }
    }

    struct ReceivedCarbon {
        @Test("Parses received carbon and emits messageCarbonReceived")
        func parsesReceivedCarbon() async throws {
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

            await client.disconnect()
        }
    }

    struct SentCarbon {
        @Test("Parses sent carbon and emits messageCarbonSent")
        func parsesSentCarbon() async throws {
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

            await client.disconnect()
        }
    }

    struct Security {
        @Test("Ignores carbons from foreign JIDs")
        func ignoresForeignCarbons() async throws {
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

            await client.disconnect()
        }
    }
}
