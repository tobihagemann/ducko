import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(MUCModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

// MARK: - Tests

enum MUCModuleCorrectionTests {
    struct IncomingCorrection {
        @Test
        func `Groupchat correction emits messageCorrected`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageCorrected = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message type='groupchat' from='room@conference.example.com/alice' id='msg-2'>\
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
            #expect(from.bareJID == testRoomJID)

            await client.disconnect()
        }

        @Test
        func `Correction without body is ignored`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client, timeout: .seconds(1)) { event in
                    if case .messageCorrected = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message type='groupchat' from='room@conference.example.com/alice' id='msg-2'>\
            <replace xmlns='urn:xmpp:message-correct:0' id='msg-1'/>\
            </message>
            """)

            do {
                _ = try await eventsTask.value
                throw XMPPClientError.unexpectedStreamState("Should not emit event")
            } catch is XMPPClientError {
                // Expected — timeout because no messageCorrected event was emitted
            }

            await client.disconnect()
        }
    }

    struct SendCorrection {
        @Test
        func `Sends correction XML with replace element`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            await mock.clearSentBytes()

            try await module.sendCorrection(to: testRoomJID, body: "Fixed text", replacingID: "orig-1")

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let correctionMsg = sentStrings.first {
                $0.contains("<replace") && $0.contains("urn:xmpp:message-correct:0") && $0.contains("id=\"orig-1\"")
            }
            #expect(correctionMsg != nil)
            if let msg = correctionMsg {
                #expect(msg.contains("Fixed text"))
                #expect(msg.contains("type=\"groupchat\""))
            }

            await client.disconnect()
        }
    }
}
