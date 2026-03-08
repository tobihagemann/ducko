import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock
    )
    await client.register(VCardModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum VCardModuleTests {
    struct VCardParsing {
        @Test
        func `Parses FN and NICKNAME from vCard response`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            let fetchTask = Task {
                try await module.fetchVCard(for: BareJID.parse("contact@example.com")!)
            }

            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let vcardIQ = sentStrings.last { $0.contains("vcard-temp") }

            if let iqStr = vcardIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='contact@example.com'>\
                <vCard xmlns='vcard-temp'>\
                <FN>Alice Smith</FN>\
                <NICKNAME>alice</NICKNAME>\
                </vCard>\
                </iq>
                """)
            }

            let vcard = try await fetchTask.value
            #expect(vcard?.fullName == "Alice Smith")
            #expect(vcard?.nickname == "alice")
            #expect(vcard?.photoData == nil)

            await client.disconnect()
        }

        @Test
        func `Parses PHOTO/BINVAL and computes SHA-1 hash`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            // Base64 of "test photo data"
            let photoBase64 = Base64.encode(Array("test photo data".utf8))

            let fetchTask = Task {
                try await module.fetchVCard(for: BareJID.parse("contact@example.com")!)
            }

            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let vcardIQ = sentStrings.last { $0.contains("vcard-temp") }

            if let iqStr = vcardIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='contact@example.com'>\
                <vCard xmlns='vcard-temp'>\
                <FN>Alice</FN>\
                <PHOTO>\
                <TYPE>image/png</TYPE>\
                <BINVAL>\(photoBase64)</BINVAL>\
                </PHOTO>\
                </vCard>\
                </iq>
                """)
            }

            let vcard = try await fetchTask.value
            #expect(vcard?.photoData == Array("test photo data".utf8))
            #expect(vcard?.photoHash != nil)
            #expect(vcard?.photoHash?.isEmpty == false)

            await client.disconnect()
        }
    }

    struct VCardCaching {
        @Test
        func `Cache hit returns without IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            let jid = try #require(BareJID.parse("contact@example.com"))

            // First fetch — will send IQ
            let fetchTask = Task {
                try await module.fetchVCard(for: jid)
            }

            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let vcardIQ = sentStrings.last { $0.contains("vcard-temp") }

            if let iqStr = vcardIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='contact@example.com'>\
                <vCard xmlns='vcard-temp'><FN>Alice</FN></vCard>\
                </iq>
                """)
            }

            _ = try await fetchTask.value

            // Clear sent bytes and do second fetch — should not send IQ
            await mock.clearSentBytes()

            let cachedResult = try await module.fetchVCard(for: jid)
            #expect(cachedResult?.fullName == "Alice")

            let newSentData = await mock.sentBytes
            let hasVCardIQ = newSentData.map { String(decoding: $0, as: UTF8.self) }.contains { $0.contains("vcard-temp") }
            #expect(!hasVCardIQ)

            await client.disconnect()
        }

        @Test
        func `forceRefresh bypasses cache`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            let jid = try #require(BareJID.parse("contact@example.com"))

            // First fetch
            let fetchTask1 = Task {
                try await module.fetchVCard(for: jid)
            }

            try? await Task.sleep(for: .milliseconds(100))

            var sentData = await mock.sentBytes
            var sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            var vcardIQ = sentStrings.last { $0.contains("vcard-temp") }

            if let iqStr = vcardIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='contact@example.com'>\
                <vCard xmlns='vcard-temp'><FN>Alice</FN></vCard>\
                </iq>
                """)
            }

            _ = try await fetchTask1.value

            // Force refresh — should send new IQ
            await mock.clearSentBytes()

            let fetchTask2 = Task {
                try await module.fetchVCard(for: jid, forceRefresh: true)
            }

            try? await Task.sleep(for: .milliseconds(100))

            sentData = await mock.sentBytes
            sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            vcardIQ = sentStrings.last { $0.contains("vcard-temp") }

            // Should have sent a new IQ
            #expect(vcardIQ != nil)

            if let iqStr = vcardIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='contact@example.com'>\
                <vCard xmlns='vcard-temp'><FN>Alice Updated</FN></vCard>\
                </iq>
                """)
            }

            let vcard = try await fetchTask2.value
            #expect(vcard?.fullName == "Alice Updated")

            await client.disconnect()
        }
    }
}
