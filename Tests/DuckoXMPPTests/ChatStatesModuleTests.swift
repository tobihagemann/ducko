import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(ChatStatesModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum ChatStatesModuleTests {
    struct IncomingStates {
        @Test
        func `Emits chatStateChanged for composing`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .chatStateChanged = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat'>\
            <composing xmlns='http://jabber.org/protocol/chatstates'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .chatStateChanged(from, state) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected chatStateChanged")
            }
            #expect(from.description == "contact@example.com")
            #expect(state == .composing)

            await client.disconnect()
        }

        @Test
        func `Emits chatStateChanged for active`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .chatStateChanged = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat'>\
            <active xmlns='http://jabber.org/protocol/chatstates'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .chatStateChanged(_, state) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected chatStateChanged")
            }
            #expect(state == .active)

            await client.disconnect()
        }

        @Test
        func `Emits chatStateChanged for paused`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .chatStateChanged = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat'>\
            <paused xmlns='http://jabber.org/protocol/chatstates'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .chatStateChanged(_, state) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected chatStateChanged")
            }
            #expect(state == .paused)

            await client.disconnect()
        }
    }

    struct SendState {
        @Test
        func `Sends composing chat state XML`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ChatStatesModule.self))

            await mock.clearSentBytes()

            let jid = try #require(JID.parse("contact@example.com"))
            try await module.sendChatState(.composing, to: jid)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let composingMsg = sentStrings.first {
                $0.contains("<composing") && $0.contains("http://jabber.org/protocol/chatstates")
            }
            #expect(composingMsg != nil)

            await client.disconnect()
        }
    }

    struct ActiveOnContentMessage {
        @Test
        func `sendMessage includes active chat state element`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(ChatStatesModule())
            await client.register(ChatModule())

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let module = try #require(await client.module(ofType: ChatModule.self))

            await mock.clearSentBytes()

            let jid = try #require(JID.parse("contact@example.com"))
            try await module.sendMessage(to: jid, body: "Hello!")

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let msg = sentStrings.first { $0.contains("Hello!") }
            #expect(msg != nil)
            #expect(msg?.contains("<active") == true)
            #expect(msg?.contains("http://jabber.org/protocol/chatstates") == true)

            await client.disconnect()
        }

        @Test
        func `sendMessage with includeChatState false omits active element`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(ChatStatesModule())
            await client.register(ChatModule())

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let module = try #require(await client.module(ofType: ChatModule.self))

            await mock.clearSentBytes()

            let jid = try #require(JID.parse("contact@example.com"))
            try await module.sendMessage(to: jid, body: "Hello!", includeChatState: false)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let msg = sentStrings.first { $0.contains("Hello!") }
            #expect(msg != nil)
            let hasActive = msg?.contains("<active") ?? false
            #expect(!hasActive)

            await client.disconnect()
        }
    }

    struct GoneSuppressedInGroupchat {
        @Test
        func `Suppresses gone in groupchat`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ChatStatesModule.self))

            await mock.clearSentBytes()

            let jid = try #require(JID.parse("room@conference.example.com"))
            try await module.sendChatState(.gone, to: jid, messageType: .groupchat)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let goneMsg = sentStrings.first { $0.contains("<gone") }
            #expect(goneMsg == nil)

            await client.disconnect()
        }

        @Test
        func `Allows composing in groupchat`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ChatStatesModule.self))

            await mock.clearSentBytes()

            let jid = try #require(JID.parse("room@conference.example.com"))
            try await module.sendChatState(.composing, to: jid, messageType: .groupchat)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let composingMsg = sentStrings.first { $0.contains("<composing") }
            #expect(composingMsg != nil)

            await client.disconnect()
        }
    }

    struct StandaloneVsWithBody {
        @Test
        func `Standalone chat state (no body) still emits event`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .chatStateChanged = event { return true }
                    return false
                }
            }

            // No <body> — standalone chat state notification
            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat'>\
            <gone xmlns='http://jabber.org/protocol/chatstates'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .chatStateChanged(_, state) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected chatStateChanged")
            }
            #expect(state == .gone)

            await client.disconnect()
        }
    }
}
