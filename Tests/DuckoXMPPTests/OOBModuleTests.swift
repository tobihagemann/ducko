import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(OOBModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum OOBModuleTests {
    struct IncomingOffer {
        @Test
        func `Emits event for valid incoming OOB IQ offer`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let events = client.events
            let eventTask = Task<XMPPEvent?, Never> {
                for await event in events {
                    if case .oobIQOfferReceived = event { return event }
                }
                return nil
            }

            await mock.simulateReceive("""
            <iq type='set' from='sender@example.com/res' id='oob-1'>\
            <query xmlns='jabber:iq:oob'>\
            <url>https://example.com/file.txt</url>\
            <desc>A text file</desc>\
            </query></iq>
            """)

            let event = await eventTask.value
            guard case let .oobIQOfferReceived(offer) = event else {
                Issue.record("Expected oobIQOfferReceived event")
                return
            }
            #expect(offer.id == "oob-1")
            #expect(offer.url == "https://example.com/file.txt")
            #expect(offer.desc == "A text file")
            #expect(offer.from.bareJID.description == "sender@example.com")

            await client.disconnect()
        }

        @Test
        func `Ignores IQ with wrong namespace`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            await mock.simulateReceive("""
            <iq type='set' from='sender@example.com/res' id='wrong-ns'>\
            <query xmlns='jabber:x:oob'>\
            <url>https://example.com/file.txt</url>\
            </query></iq>
            """)

            // The module should not handle this IQ (wrong namespace: jabber:x:oob instead of jabber:iq:oob).
            // The client should respond with service-unavailable.
            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let errorIQ = sentStrings.first { $0.contains("service-unavailable") }
            #expect(errorIQ != nil)

            await client.disconnect()
        }
    }

    struct AcceptOffer {
        @Test
        func `Sends IQ result on accept`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.simulateReceive("""
            <iq type='set' from='sender@example.com/res' id='accept-1'>\
            <query xmlns='jabber:iq:oob'>\
            <url>https://example.com/file.txt</url>\
            </query></iq>
            """)

            // Wait for the event to be processed
            try? await Task.sleep(for: .milliseconds(50))
            await mock.clearSentBytes()

            let oobModule = try #require(await client.module(ofType: OOBModule.self))
            try await oobModule.acceptOffer(id: "accept-1")

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let resultIQ = sentStrings.first { $0.contains("id=\"accept-1\"") && $0.contains("type=\"result\"") }
            #expect(resultIQ != nil)
            #expect(resultIQ?.contains("to=\"sender@example.com/res\"") == true)

            await client.disconnect()
        }
    }

    struct RejectOffer {
        @Test
        func `Sends not-acceptable error on reject`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.simulateReceive("""
            <iq type='set' from='sender@example.com/res' id='reject-1'>\
            <query xmlns='jabber:iq:oob'>\
            <url>https://example.com/file.txt</url>\
            </query></iq>
            """)

            // Wait for the event to be processed
            try? await Task.sleep(for: .milliseconds(50))
            await mock.clearSentBytes()

            let oobModule = try #require(await client.module(ofType: OOBModule.self))
            try await oobModule.rejectOffer(id: "reject-1")

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let errorIQ = sentStrings.first { $0.contains("id=\"reject-1\"") && $0.contains("type=\"error\"") }
            #expect(errorIQ != nil)
            #expect(errorIQ?.contains("not-acceptable") == true)

            await client.disconnect()
        }
    }

    struct DiscoFeature {
        @Test
        func `Advertises jabber:iq:oob in disco features`() {
            let module = OOBModule()
            #expect(module.features.contains(XMPPNamespaces.oobIQ))
        }
    }
}
