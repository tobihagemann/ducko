import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock
    )
    await client.register(ChatModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum ChatModuleCorrectionTests {
    struct IncomingCorrection {
        @Test
        func `Emits messageCorrected for incoming correction`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageCorrected = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat' id='msg-2'>\
            <body>Hello (corrected)</body>\
            <replace xmlns='urn:xmpp:message-correct:0' id='msg-1'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageCorrected(originalID, newBody, from) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageCorrected")
            }
            #expect(originalID == "msg-1")
            #expect(newBody == "Hello (corrected)")
            #expect(from.bareJID.description == "contact@example.com")

            await client.disconnect()
        }
    }

    struct SendCorrection {
        @Test
        func `Sends correction XML with replace element`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ChatModule.self))

            await mock.clearSentBytes()

            let recipient = try #require(JID.parse("contact@example.com"))
            try await module.sendCorrection(to: recipient, body: "Fixed text", replacingID: "orig-1")

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let correctionMsg = sentStrings.first {
                $0.contains("<replace") && $0.contains("urn:xmpp:message-correct:0") && $0.contains("id=\"orig-1\"")
            }
            #expect(correctionMsg != nil)
            if let msg = correctionMsg {
                #expect(msg.contains("Fixed text"))
            }

            await client.disconnect()
        }
    }

    struct SendReply {
        @Test
        func `Sends reply XML with reply element`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ChatModule.self))

            await mock.clearSentBytes()

            let recipient = try #require(JID.parse("contact@example.com"))
            try await module.sendReply(
                to: recipient,
                body: "Reply text",
                replyToID: "quoted-1",
                replyToJID: recipient
            )

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let replyMsg = sentStrings.first {
                $0.contains("<reply") && $0.contains("urn:xmpp:reply:0") && $0.contains("id=\"quoted-1\"")
            }
            #expect(replyMsg != nil)
            if let msg = replyMsg {
                #expect(msg.contains("Reply text"))
            }

            await client.disconnect()
        }
    }

    struct MessageError {
        @Test
        func `Emits messageError for error-type message`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageError = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='error' id='msg-err'>\
            <error type='cancel'>\
            <service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>\
            </error>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageError(messageID, from, error) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageError")
            }
            #expect(messageID == "msg-err")
            #expect(from.bareJID.description == "contact@example.com")
            #expect(error.condition == .serviceUnavailable)

            await client.disconnect()
        }
    }
}
