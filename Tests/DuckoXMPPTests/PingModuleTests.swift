import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock
    )
    await client.register(PingModule(pingInterval: .milliseconds(200)))

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum PingModuleTests {
    struct IncomingPing {
        @Test("Responds to incoming ping IQ with result")
        func respondsToIncomingPing() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            await mock.simulateReceive(
                "<iq type='get' from='example.com' id='ping-1'><ping xmlns='urn:xmpp:ping'/></iq>"
            )

            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let pongIQ = sentStrings.first { $0.contains("id=\"ping-1\"") && $0.contains("type=\"result\"") }
            #expect(pongIQ != nil)
            #expect(pongIQ?.contains("to=\"example.com\"") == true)

            await client.disconnect()
        }
    }

    struct Keepalive {
        @Test("Sends keepalive pings on interval")
        func sendsKeepalivePings() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            // Wait for at least one keepalive ping (interval is 200ms)
            try? await Task.sleep(for: .milliseconds(350))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let pingIQ = sentStrings.first { $0.contains("<ping") && $0.contains("urn:xmpp:ping") }
            #expect(pingIQ != nil)

            // Respond to avoid timeout blocking
            if let iqStr = pingIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
            }

            await client.disconnect()
        }

        @Test("Stops keepalive on disconnect")
        func stopsKeepaliveOnDisconnect() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await client.disconnect()
            await mock.clearSentBytes()

            // Wait longer than the keepalive interval
            try? await Task.sleep(for: .milliseconds(350))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let pingIQ = sentStrings.first { $0.contains("<ping") && $0.contains("urn:xmpp:ping") }
            #expect(pingIQ == nil)
        }
    }

    struct PublicAPI {
        @Test("ping(jid:) returns on success")
        func pingReturnsOnSuccess() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: PingModule.self))

            await mock.clearSentBytes()

            let pingTask = Task {
                try await module.ping(jid: .bare(BareJID(localPart: "contact", domainPart: "example.com")!))
            }

            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let pingIQ = sentStrings.first { $0.contains("<ping") && $0.contains("to=\"contact@example.com\"") }
            #expect(pingIQ != nil)

            if let iqStr = pingIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("<iq type='result' id='\(iqID)' from='contact@example.com'/>")
            }

            try await pingTask.value

            await client.disconnect()
        }
    }
}
