import Testing
@testable import DuckoXMPP

// MARK: - Tests

enum XMPPClientSASL2Tests {
    struct SASL2Connect {
        @Test
        func `Connects via SASL2 and Bind 2 when server supports it`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let sm = StreamManagementModule()
            await client.register(sm)
            await client.addInterceptor(sm)
            await client.register(CarbonsModule())

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSASL2Connect(mock)
            try await connectTask.value

            // Verify authenticate element was sent with SASL2 namespace
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let authSent = sentStrings.first { $0.contains("urn:xmpp:sasl:2") }
            #expect(authSent != nil)
            #expect(authSent?.contains("urn:xmpp:bind:0") == true)

            // SM should be enabled inline
            #expect(sm.isResumable)

            await client.disconnect()
        }
    }

    struct FallbackToSASL1 {
        @Test
        func `Falls back to SASL1 when server does not advertise SASL2`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            // Use the standard SASL1 flow
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            // Verify auth element used SASL1 namespace
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let authSent = sentStrings.first { $0.contains("urn:ietf:params:xml:ns:xmpp-sasl") }
            #expect(authSent != nil)

            // No SASL2 auth should have been sent
            let sasl2Sent = sentStrings.first { $0.contains("urn:xmpp:sasl:2") }
            #expect(sasl2Sent == nil)

            await client.disconnect()
        }
    }

    struct InlineSMEnable {
        @Test
        func `SM is enabled inline via Bind 2 and skips separate enable`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let sm = StreamManagementModule()
            await client.register(sm)
            await client.addInterceptor(sm)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSASL2Connect(mock)
            try await connectTask.value

            // SM should be enabled via inline, no separate <enable> IQ
            #expect(sm.isResumable)

            // After connect, check that no separate SM <enable> was sent
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let separateSMEnable = sentStrings.filter {
                $0.contains("<enable xmlns='urn:xmpp:sm:3'") && !$0.contains("urn:xmpp:sasl:2")
            }
            let count = separateSMEnable.count
            #expect(count == 0)

            await client.disconnect()
        }
    }

    struct InlineCarbonsEnable {
        @Test
        func `Carbons are enabled inline and module skips separate IQ`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(CarbonsModule())

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSASL2Connect(mock)
            try await connectTask.value

            // After connect, check that no separate carbons enable IQ was sent
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let carbonsIQ = sentStrings.filter {
                $0.contains("<enable xmlns='urn:xmpp:carbons:2'") && $0.contains("type='set'")
            }
            let count = carbonsIQ.count
            #expect(count == 0)

            await client.disconnect()
        }
    }
}
