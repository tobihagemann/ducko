import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(ReceiptsModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum ReceiptsModuleTests {
    struct AutoReply {
        @Test
        func `Auto-replies with receipt for chat message with body and request`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat' id='msg-1'>\
            <body>Hello</body>\
            <request xmlns='urn:xmpp:receipts'/>\
            </message>
            """)

            try? await Task.sleep(for: .milliseconds(200))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let receiptReply = sentStrings.first { $0.contains("urn:xmpp:receipts") && $0.contains("<received") }
            #expect(receiptReply != nil)
            if let reply = receiptReply {
                #expect(reply.contains("id=\"msg-1\""))
            }

            await client.disconnect()
        }

        @Test
        func `Does not auto-reply for groupchat messages`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            await mock.simulateReceive("""
            <message from='room@example.com/nick' to='user@example.com/ducko' type='groupchat' id='msg-2'>\
            <body>Hello room</body>\
            <request xmlns='urn:xmpp:receipts'/>\
            </message>
            """)

            try? await Task.sleep(for: .milliseconds(200))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let receiptReply = sentStrings.first { $0.contains("urn:xmpp:receipts") && $0.contains("<received") }
            #expect(receiptReply == nil)

            await client.disconnect()
        }

        @Test
        func `Does not auto-reply for messages without body`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat' id='msg-3'>\
            <request xmlns='urn:xmpp:receipts'/>\
            </message>
            """)

            try? await Task.sleep(for: .milliseconds(200))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let receiptReply = sentStrings.first { $0.contains("urn:xmpp:receipts") && $0.contains("<received") }
            #expect(receiptReply == nil)

            await client.disconnect()
        }
    }

    struct ReceiptReceived {
        @Test
        func `Emits deliveryReceiptReceived when receipt arrives`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .deliveryReceiptReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat'>\
            <received xmlns='urn:xmpp:receipts' id='original-msg'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .deliveryReceiptReceived(messageID, from) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected deliveryReceiptReceived")
            }
            #expect(messageID == "original-msg")
            #expect(from.bareJID.description == "contact@example.com")

            await client.disconnect()
        }
    }

    struct ChatMarkers {
        @Test
        func `Emits chatMarkerReceived for displayed marker`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .chatMarkerReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat'>\
            <displayed xmlns='urn:xmpp:chat-markers:0' id='msg-42'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .chatMarkerReceived(messageID, markerType, _) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected chatMarkerReceived")
            }
            #expect(messageID == "msg-42")
            #expect(markerType == .displayed)

            await client.disconnect()
        }
    }
}
