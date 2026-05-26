import DuckoTestSupport
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

/// Builds an IBB close IQ.
private func ibbCloseXML(
    id: String = "ibb-close-1",
    from: String = "peer@example.com/res",
    ibbSID: String = "ibb-fallback"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <close xmlns='http://jabber.org/protocol/ibb' sid='\(ibbSID)'/>\
    </iq>
    """
}

/// Builds a session-terminate IQ.
private func sessionTerminateXML(
    id: String = "jingle-terminate-1",
    sid: String = "sid-ibb-test",
    from: String = "peer@example.com/res",
    reason: String = "success"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='\(sid)'>\
    <reason><\(reason)/></reason>\
    </jingle>\
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

    struct IBBCloseEmitsCompletion {
        @Test
        func `IBB close emits jingleFileTransferCompleted with .ibb`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferCompleted = event { return true }
                    return false
                }
            }

            // Establish IBB transport via transport-replace, then close
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(100))
            await mock.simulateReceive(transportReplaceXML())
            try? await Task.sleep(for: .milliseconds(100))
            await mock.simulateReceive(ibbCloseXML())

            let events = try await eventsTask.value
            guard case let .jingleFileTransferCompleted(sid, transport) = events.last else {
                Issue.record("Expected jingleFileTransferCompleted event")
                await client.disconnect()
                return
            }
            #expect(sid == "sid-ibb-test")
            #expect(transport == .ibb)

            await client.disconnect()
        }
    }

    struct IBBCloseFollowedByTerminateEmitsOnce {
        @Test
        func `IBB close then session-terminate(success) emits exactly one completion`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Use disconnect as a sentinel to stop event collection — collect
            // every event up to and including the disconnect event.
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(100))
            await mock.simulateReceive(transportReplaceXML())
            try? await Task.sleep(for: .milliseconds(100))
            await mock.simulateReceive(ibbCloseXML())
            try? await Task.sleep(for: .milliseconds(100))
            await mock.simulateReceive(sessionTerminateXML(reason: "success"))
            try? await Task.sleep(for: .milliseconds(100))

            await client.disconnect()

            let events = try await eventsTask.value
            let completions = events.filter {
                if case .jingleFileTransferCompleted = $0 { return true }
                return false
            }
            #expect(completions.count == 1)
            if case let .jingleFileTransferCompleted(completedSID, transport) = completions.first {
                #expect(completedSID == "sid-ibb-test")
                #expect(transport == .ibb)
            }
        }
    }
}
