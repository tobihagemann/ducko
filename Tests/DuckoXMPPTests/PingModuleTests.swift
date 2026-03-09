import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
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
        @Test
        func `Responds to incoming ping IQ with result`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            await mock.simulateReceive(
                "<iq type='get' from='example.com' id='ping-1'><ping xmlns='urn:xmpp:ping'/></iq>"
            )

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let pongIQ = sentStrings.first { $0.contains("id=\"ping-1\"") && $0.contains("type=\"result\"") }
            #expect(pongIQ != nil)
            #expect(pongIQ?.contains("to=\"example.com\"") == true)

            await client.disconnect()
        }
    }

    struct Keepalive {
        @Test
        func `Sends keepalive pings on interval`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            // Wait for at least one keepalive ping
            await mock.waitForSent(count: 1)

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

        @Test
        func `Stops keepalive on disconnect`() async throws {
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
}
