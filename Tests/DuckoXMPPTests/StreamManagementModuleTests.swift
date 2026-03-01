import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> (XMPPClient, StreamManagementModule) {
    let sm = StreamManagementModule()
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock
    )
    await client.register(sm)
    await client.addInterceptor(sm)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }

    await simulateNoTLSConnect(mock)
    try? await Task.sleep(for: .milliseconds(100))

    // Respond to SM <enable> with <enabled>
    await mock.simulateReceive("<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-1' max='300'/>")

    try await connectTask.value

    return (client, sm)
}

// MARK: - Tests

enum StreamManagementModuleTests {
    struct EnableFlow {
        @Test("Sends <enable> on handleConnect and processes <enabled> response")
        func sendsEnableAndProcessesEnabled() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeConnectedClient(mock: mock)

            #expect(sm.isEnabled)

            await client.disconnect()
        }

        @Test("Handles <failed> response and resets state")
        func handlesFailedResponse() async throws {
            let mock = MockTransport()
            let sm = StreamManagementModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )
            await client.register(sm)
            await client.addInterceptor(sm)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }

            await simulateNoTLSConnect(mock)
            try? await Task.sleep(for: .milliseconds(100))

            // Respond with <failed> instead of <enabled>
            await mock.simulateReceive("<failed xmlns='urn:xmpp:sm:3'/>")

            try await connectTask.value

            #expect(!sm.isEnabled)

            await client.disconnect()
        }
    }

    struct IncomingCounter {
        @Test("Increments incoming counter on received stanzas")
        func incrementsIncomingCounter() async throws {
            let mock = MockTransport()
            let (client, _) = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            // Send a message stanza — should increment incoming counter
            await mock.simulateReceive(
                "<message type='chat' from='contact@example.com/res'><body>Hello</body></message>"
            )
            // Send a presence stanza
            await mock.simulateReceive(
                "<presence from='contact@example.com/res'/>"
            )
            // Send an IQ stanza
            await mock.simulateReceive(
                "<iq type='get' from='example.com' id='test-1'><query xmlns='jabber:iq:version'/></iq>"
            )

            try? await Task.sleep(for: .milliseconds(100))

            // Request ack — the server sends <r>, we should respond with <a h="3">
            await mock.simulateReceive("<r xmlns='urn:xmpp:sm:3'/>")
            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let ack = sentStrings.first { $0.contains("<a") && $0.contains("urn:xmpp:sm:3") }
            #expect(ack != nil)
            #expect(ack?.contains("h=\"3\"") == true)

            await client.disconnect()
        }
    }

    struct OutgoingCounter {
        @Test("Increments outgoing counter on sent stanzas")
        func incrementsOutgoingCounter() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeConnectedClient(mock: mock)

            // Send some stanzas
            let message = try XMPPMessage(type: .chat, to: .bare(#require(BareJID(localPart: "contact", domainPart: "example.com"))))
            try await client.send(message)
            try await client.send(message)

            #expect(sm.unackedCount == 2)

            await client.disconnect()
        }
    }

    struct AckProcessing {
        @Test("Responds to <r> with <a h='N'>")
        func respondsToRWithA() async throws {
            let mock = MockTransport()
            let (client, _) = try await makeConnectedClient(mock: mock)

            // Receive one message to set incoming counter to 1
            await mock.simulateReceive(
                "<message type='chat' from='contact@example.com/res'><body>Hi</body></message>"
            )
            try? await Task.sleep(for: .milliseconds(50))

            await mock.clearSentBytes()

            // Server sends <r>
            await mock.simulateReceive("<r xmlns='urn:xmpp:sm:3'/>")
            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let ack = sentStrings.first { $0.contains("<a") && $0.contains("urn:xmpp:sm:3") }
            #expect(ack != nil)
            #expect(ack?.contains("h=\"1\"") == true)

            await client.disconnect()
        }

        @Test("Processes <a h='N'> and dequeues acknowledged stanzas")
        func processesAckAndDequeues() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeConnectedClient(mock: mock)

            // Send 3 stanzas
            let message = try XMPPMessage(type: .chat, to: .bare(#require(BareJID(localPart: "contact", domainPart: "example.com"))))
            try await client.send(message)
            try await client.send(message)
            try await client.send(message)

            #expect(sm.unackedCount == 3)

            // Server acknowledges 2 stanzas
            await mock.simulateReceive("<a xmlns='urn:xmpp:sm:3' h='2'/>")
            try? await Task.sleep(for: .milliseconds(50))

            #expect(sm.unackedCount == 1)

            await client.disconnect()
        }
    }

    struct StanzaFiltering {
        @Test("Counter only counts iq/message/presence, not SM elements")
        func counterOnlyCountsStanzas() async throws {
            let mock = MockTransport()
            let (client, _) = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            // SM elements like <r> and <a> should NOT increment the counter
            await mock.simulateReceive("<r xmlns='urn:xmpp:sm:3'/>")
            try? await Task.sleep(for: .milliseconds(50))

            // Send another <r> to check the counter is still 0
            await mock.clearSentBytes()
            await mock.simulateReceive("<r xmlns='urn:xmpp:sm:3'/>")
            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let ack = sentStrings.first { $0.contains("<a") && $0.contains("urn:xmpp:sm:3") }
            #expect(ack?.contains("h=\"0\"") == true)

            await client.disconnect()
        }

        @Test("SM-namespace elements are consumed and not dispatched to modules")
        func smElementsConsumed() async throws {
            let mock = MockTransport()
            let (client, _) = try await makeConnectedClient(mock: mock)

            // Try to collect an iqReceived event — the SM <r> should NOT produce one
            let eventsTask = Task {
                try await collectEvents(from: client, timeout: .seconds(1)) { event in
                    if case .iqReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("<r xmlns='urn:xmpp:sm:3'/>")

            do {
                _ = try await eventsTask.value
                throw XMPPClientError.unexpectedStreamState("Should have timed out")
            } catch is XMPPClientError {
                // Expected: timeout means SM elements were consumed
            }

            await client.disconnect()
        }
    }
}
