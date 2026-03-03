import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock
    )
    await client.register(ServiceDiscoveryModule())
    await client.register(HTTPUploadModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

/// Responds to the disco#items query with a single upload service item.
private func respondToDiscoItems(mock: MockTransport) async {
    try? await Task.sleep(for: .milliseconds(100))
    let sentData = await mock.sentBytes
    let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
    let itemsIQ = sentStrings.last { $0.contains("disco#items") }
    if let iqStr = itemsIQ, let iqID = extractIQID(from: iqStr) {
        await mock.simulateReceive("""
        <iq type='result' id='\(iqID)' from='example.com'>\
        <query xmlns='http://jabber.org/protocol/disco#items'>\
        <item jid='upload.example.com' name='HTTP Upload'/>\
        </query>\
        </iq>
        """)
    }
}

/// Responds to the disco#info query for the upload service with the upload feature.
private func respondToDiscoInfo(mock: MockTransport, maxFileSize: Int64? = nil) async {
    try? await Task.sleep(for: .milliseconds(100))
    let sentData = await mock.sentBytes
    let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
    let infoIQ = sentStrings.last { $0.contains("disco#info") }
    if let iqStr = infoIQ, let iqID = extractIQID(from: iqStr) {
        var xml = """
        <iq type='result' id='\(iqID)' from='upload.example.com'>\
        <query xmlns='http://jabber.org/protocol/disco#info'>\
        <identity category='store' type='file'/>\
        <feature var='urn:xmpp:http:upload:0'/>
        """
        if let maxFileSize {
            xml += """
            <x xmlns='jabber:x:data' type='result'>\
            <field var='FORM_TYPE' type='hidden'><value>urn:xmpp:http:upload:0</value></field>\
            <field var='max-file-size'><value>\(maxFileSize)</value></field>\
            </x>
            """
        }
        xml += "</query></iq>"
        await mock.simulateReceive(xml)
    }
}

/// Responds to a slot request with PUT and GET URLs.
private func respondToSlotRequest(
    mock: MockTransport,
    putURL: String = "https://upload.example.com/put/abc",
    getURL: String = "https://upload.example.com/get/abc",
    headers: [(name: String, value: String)] = []
) async {
    try? await Task.sleep(for: .milliseconds(100))
    let sentData = await mock.sentBytes
    let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
    let slotIQ = sentStrings.last { $0.contains("urn:xmpp:http:upload:0") && $0.contains("request") }
    if let iqStr = slotIQ, let iqID = extractIQID(from: iqStr) {
        var putElement = "<put url='\(putURL)'>"
        for header in headers {
            putElement += "<header name='\(header.name)'>\(header.value)</header>"
        }
        putElement += "</put>"

        await mock.simulateReceive("""
        <iq type='result' id='\(iqID)' from='upload.example.com'>\
        <slot xmlns='urn:xmpp:http:upload:0'>\
        \(putElement)\
        <get url='\(getURL)'/>\
        </slot>\
        </iq>
        """)
    }
}

// MARK: - Tests

enum HTTPUploadModuleTests {
    struct DiscoverUploadService {
        @Test("Discovers upload service via disco")
        func discoversService() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: HTTPUploadModule.self))

            await mock.clearSentBytes()

            let queryTask = Task {
                try await module.discoverUploadService()
            }

            await respondToDiscoItems(mock: mock)
            await respondToDiscoInfo(mock: mock)

            let result = try await queryTask.value
            #expect(result?.jid == "upload.example.com")
            #expect(result?.maxFileSize == nil)

            await client.disconnect()
        }
    }

    struct DiscoverMaxFileSize {
        @Test("Parses max-file-size from extended disco info")
        func parsesMaxFileSize() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: HTTPUploadModule.self))

            await mock.clearSentBytes()

            let queryTask = Task {
                try await module.discoverUploadService()
            }

            await respondToDiscoItems(mock: mock)
            await respondToDiscoInfo(mock: mock, maxFileSize: 10_485_760)

            let result = try await queryTask.value
            #expect(result?.jid == "upload.example.com")
            let maxSize = try #require(result?.maxFileSize)
            #expect(maxSize == 10_485_760)

            await client.disconnect()
        }
    }

    struct RequestSlot {
        @Test("Requests and parses upload slot")
        func requestsSlot() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: HTTPUploadModule.self))

            await mock.clearSentBytes()

            let queryTask = Task {
                try await module.requestSlot(filename: "cat.jpg", size: 12345, contentType: "image/jpeg")
            }

            await respondToDiscoItems(mock: mock)
            await respondToDiscoInfo(mock: mock)
            await respondToSlotRequest(mock: mock)

            let slot = try await queryTask.value
            #expect(slot.putURL == "https://upload.example.com/put/abc")
            #expect(slot.getURL == "https://upload.example.com/get/abc")
            #expect(slot.putHeaders.isEmpty)

            await client.disconnect()
        }
    }

    struct RequestSlotWithHeaders {
        @Test("Parses PUT headers from slot response")
        func parsesHeaders() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: HTTPUploadModule.self))

            await mock.clearSentBytes()

            let queryTask = Task {
                try await module.requestSlot(filename: "doc.pdf", size: 5000, contentType: "application/pdf")
            }

            await respondToDiscoItems(mock: mock)
            await respondToDiscoInfo(mock: mock)
            await respondToSlotRequest(
                mock: mock,
                headers: [("Authorization", "Basic dXNlcjpwYXNz"), ("X-Custom", "value123")]
            )

            let slot = try await queryTask.value
            #expect(slot.putHeaders["Authorization"] == "Basic dXNlcjpwYXNz")
            #expect(slot.putHeaders["X-Custom"] == "value123")

            await client.disconnect()
        }
    }

    struct FileTooLarge {
        @Test("Throws fileTooLarge when size exceeds max")
        func throwsFileTooLarge() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: HTTPUploadModule.self))

            await mock.clearSentBytes()

            let queryTask = Task {
                try await module.requestSlot(filename: "big.zip", size: 20_000_000, contentType: "application/zip")
            }

            await respondToDiscoItems(mock: mock)
            await respondToDiscoInfo(mock: mock, maxFileSize: 10_000_000)

            do {
                _ = try await queryTask.value
                Issue.record("Expected fileTooLarge error")
            } catch let error as HTTPUploadModule.HTTPUploadError {
                if case let .fileTooLarge(maxSize) = error {
                    #expect(maxSize == 10_000_000)
                } else {
                    Issue.record("Expected fileTooLarge, got \(error)")
                }
            }

            await client.disconnect()
        }
    }

    struct NoUploadService {
        @Test("Throws noUploadServiceFound when no upload component exists")
        func throwsNoService() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: HTTPUploadModule.self))

            await mock.clearSentBytes()

            let queryTask = Task {
                try await module.requestSlot(filename: "test.txt", size: 100, contentType: "text/plain")
            }

            // Respond with items that have no upload service
            try? await Task.sleep(for: .milliseconds(100))
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let itemsIQ = sentStrings.last { $0.contains("disco#items") }
            if let iqStr = itemsIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='example.com'>\
                <query xmlns='http://jabber.org/protocol/disco#items'>\
                <item jid='conference.example.com' name='Chat Rooms'/>\
                </query>\
                </iq>
                """)
            }

            // Respond to disco#info for conference (no upload feature)
            try? await Task.sleep(for: .milliseconds(100))
            let sentData2 = await mock.sentBytes
            let sentStrings2 = sentData2.map { String(decoding: $0, as: UTF8.self) }
            let infoIQ = sentStrings2.last { $0.contains("disco#info") }
            if let iqStr = infoIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='conference.example.com'>\
                <query xmlns='http://jabber.org/protocol/disco#info'>\
                <identity category='conference' type='text'/>\
                <feature var='http://jabber.org/protocol/muc'/>\
                </query>\
                </iq>
                """)
            }

            do {
                _ = try await queryTask.value
                Issue.record("Expected noUploadServiceFound error")
            } catch is HTTPUploadModule.HTTPUploadError {
                // Expected
            }

            await client.disconnect()
        }
    }

    struct CacheClearing {
        @Test("handleDisconnect clears cached service")
        func clearsCache() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: HTTPUploadModule.self))

            await mock.clearSentBytes()

            // Discover service to populate cache
            let discoverTask = Task {
                try await module.discoverUploadService()
            }

            await respondToDiscoItems(mock: mock)
            await respondToDiscoInfo(mock: mock, maxFileSize: 5_000_000)

            let result1 = try await discoverTask.value
            #expect(result1?.jid == "upload.example.com")

            // Disconnect clears cache
            await module.handleDisconnect()

            await mock.clearSentBytes()

            // Next discovery should query again (not use cache)
            let discoverTask2 = Task {
                try await module.discoverUploadService()
            }

            await respondToDiscoItems(mock: mock)
            await respondToDiscoInfo(mock: mock, maxFileSize: 8_000_000)

            let result2 = try await discoverTask2.value
            #expect(result2?.maxFileSize == 8_000_000)

            await client.disconnect()
        }
    }
}
