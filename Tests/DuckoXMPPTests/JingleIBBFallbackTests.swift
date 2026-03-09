import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(JingleModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

/// Builds a session-initiate IQ XML string with S5B transport.
private func sessionInitiateXML(
    id: String = "jingle-1",
    sid: String = "sid-ibb-test",
    from: String = "peer@example.com/res"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='\(sid)' initiator='\(from)'>\
    <content creator='initiator' name='a-file-offer'>\
    <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>\
    <file>\
    <name>test.txt</name>\
    <size>1024</size>\
    </file>\
    </description>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='transport-sid'/>\
    </content>\
    </jingle>\
    </iq>
    """
}

/// Builds a transport-replace IQ with IBB transport.
private func transportReplaceXML(
    id: String = "tr-1",
    sid: String = "sid-ibb-test",
    from: String = "peer@example.com/res",
    ibbSID: String = "ibb-fallback",
    blockSize: Int = 4096
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='transport-replace' sid='\(sid)'>\
    <content creator='initiator' name='a-file-offer'>\
    <transport xmlns='urn:xmpp:jingle:transports:ibb:1' sid='\(ibbSID)' block-size='\(blockSize)'/>\
    </content>\
    </jingle>\
    </iq>
    """
}

/// Builds a transport-reject IQ.
private func transportRejectXML(
    id: String = "tr-reject-1",
    sid: String = "sid-ibb-test",
    from: String = "peer@example.com/res"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='transport-reject' sid='\(sid)'/>\
    </iq>
    """
}

/// Builds an IBB data IQ.
private func ibbDataXML(
    id: String = "ibb-data-1",
    from: String = "peer@example.com/res",
    ibbSID: String = "ibb-fallback",
    seq: UInt16 = 0,
    base64Data: String = "AQID"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <data xmlns='http://jabber.org/protocol/ibb' sid='\(ibbSID)' seq='\(seq)'>\(base64Data)</data>\
    </iq>
    """
}

// MARK: - Tests

enum JingleIBBFallbackTests {
    struct TransportReplaceTriggersAccept {
        @Test
        func `Receiving transport-replace with IBB triggers transport-accept response`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Create a session first
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(200))

            await mock.clearSentBytes()

            // Receive transport-replace with IBB
            await mock.simulateReceive(transportReplaceXML())
            try? await Task.sleep(for: .milliseconds(200))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }

            // Should have sent transport-accept
            let acceptIQ = sentStrings.first { $0.contains("transport-accept") }
            #expect(acceptIQ != nil)
            #expect(acceptIQ?.contains("urn:xmpp:jingle:transports:ibb:1") == true)

            await client.disconnect()
        }
    }

    struct TransportRejectEmitsFailure {
        @Test
        func `Receiving transport-reject emits jingleFileTransferFailed event`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Create a session
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(200))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed = event { return true }
                    return false
                }
            }

            // Receive transport-reject
            await mock.simulateReceive(transportRejectXML())

            let events = try await eventsTask.value
            guard case let .jingleFileTransferFailed(sid, reason) = events.last else {
                Issue.record("Expected jingleFileTransferFailed event")
                await client.disconnect()
                return
            }
            #expect(sid == "sid-ibb-test")
            #expect(reason == "transport-reject")

            await client.disconnect()
        }
    }

    struct IBBDataAcknowledged {
        @Test
        func `IBB data IQ is acknowledged with IQ result`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Create session and establish IBB transport
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(200))
            await mock.simulateReceive(transportReplaceXML())
            try? await Task.sleep(for: .milliseconds(200))

            await mock.clearSentBytes()

            // Send IBB data
            await mock.simulateReceive(ibbDataXML())
            try? await Task.sleep(for: .milliseconds(200))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }

            // Should have sent IQ result acknowledging the data
            let ackIQ = sentStrings.first { $0.contains("type=\"result\"") && $0.contains("ibb-data-1") }
            #expect(ackIQ != nil)

            await client.disconnect()
        }
    }
}
