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

/// Builds a session-initiate IQ XML string for testing.
private func sessionInitiateXML(
    id: String = "jingle-1",
    sid: String = "sid-123",
    from: String = "peer@example.com/res",
    fileName: String = "test.txt",
    fileSize: Int64 = 1024,
    mediaType: String? = "text/plain",
    senders: String? = nil
) -> String {
    var mediaTypeXML = ""
    if let mediaType {
        mediaTypeXML = "<media-type>\(mediaType)</media-type>"
    }
    let sendersAttr = senders.map { " senders='\($0)'" } ?? ""
    return """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='\(sid)' initiator='\(from)'>\
    <content creator='initiator' name='a-file-offer'\(sendersAttr)>\
    <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>\
    <file>\
    <name>\(fileName)</name>\
    <size>\(fileSize)</size>\
    \(mediaTypeXML)\
    </file>\
    </description>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='transport-sid'/>\
    </content>\
    </jingle>\
    </iq>
    """
}

/// Builds a session-info checksum IQ XML string for testing.
private func sessionInfoChecksumXML(
    id: String = "jingle-info-1",
    sid: String = "sid-123",
    from: String = "peer@example.com/res",
    contentName: String = "a-file-offer",
    algo: String = "sha-256",
    hash: String = "dGVzdA=="
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='session-info' sid='\(sid)'>\
    <checksum xmlns='urn:xmpp:jingle:apps:file-transfer:5' name='\(contentName)'>\
    <file>\
    <hash xmlns='urn:xmpp:hashes:2' algo='\(algo)'>\(hash)</hash>\
    </file>\
    </checksum>\
    </jingle>\
    </iq>
    """
}

/// Builds a session-terminate IQ XML string for testing.
private func sessionTerminateXML(
    id: String = "jingle-2",
    sid: String = "sid-123",
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

enum JingleModuleTests {
    struct SessionInitiateHandling {
        @Test
        func `Emits jingleFileTransferReceived on session-initiate`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(sessionInitiateXML())

            let events = try await eventsTask.value
            guard case let .jingleFileTransferReceived(offer) = events.last else {
                Issue.record("Expected jingleFileTransferReceived event")
                await client.disconnect()
                return
            }
            #expect(offer.sid == "sid-123")
            #expect(offer.fileName == "test.txt")
            #expect(offer.fileSize == 1024)
            #expect(offer.mediaType == "text/plain")
            #expect(offer.from.description == "peer@example.com/res")

            await client.disconnect()
        }
    }

    struct SessionTerminateSuccess {
        @Test
        func `Emits jingleFileTransferCompleted on session-terminate with success reason`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferCompleted = event { return true }
                    return false
                }
            }

            // First send session-initiate to create the session
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(100))
            // Then terminate it with success
            await mock.simulateReceive(sessionTerminateXML(reason: "success"))

            let events = try await eventsTask.value
            guard case let .jingleFileTransferCompleted(sid) = events.last else {
                Issue.record("Expected jingleFileTransferCompleted event")
                await client.disconnect()
                return
            }
            #expect(sid == "sid-123")

            await client.disconnect()
        }
    }

    struct SessionTerminateFailure {
        @Test
        func `Emits jingleFileTransferFailed on session-terminate with cancel reason`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(100))
            await mock.simulateReceive(sessionTerminateXML(reason: "cancel"))

            let events = try await eventsTask.value
            guard case let .jingleFileTransferFailed(sid, reason) = events.last else {
                Issue.record("Expected jingleFileTransferFailed event")
                await client.disconnect()
                return
            }
            #expect(sid == "sid-123")
            #expect(reason == "cancel")

            await client.disconnect()
        }
    }

    struct DeclineFileTransfer {
        @Test
        func `declineFileTransfer sends session-terminate with decline reason`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))

            // Simulate receiving a session-initiate
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(200))

            await mock.clearSentBytes()

            // Decline the transfer
            try await module.declineFileTransfer(sid: "sid-123")
            try? await Task.sleep(for: .milliseconds(100))

            // Verify session-terminate was sent with decline reason
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let terminateIQ = sentStrings.first { $0.contains("session-terminate") }
            #expect(terminateIQ != nil)
            #expect(terminateIQ?.contains("<decline/>") == true)

            await client.disconnect()
        }
    }

    struct IBBOpenHandshake {
        @Test
        func `Incoming IBB open is acknowledged`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Simulate session-initiate + transport-replace to set up IBB
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(200))

            // Simulate IBB open from the initiator
            await mock.clearSentBytes()
            await mock.simulateReceive("""
            <iq type='set' id='ibb-open-1' from='peer@example.com/res'>\
            <open xmlns='http://jabber.org/protocol/ibb' sid='ibb-sid-1' block-size='4096' stanza='iq'/>\
            </iq>
            """)

            try? await Task.sleep(for: .milliseconds(200))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let ackIQ = sentStrings.first { $0.contains("type=\"result\"") && $0.contains("ibb-open-1") }
            #expect(ackIQ != nil)

            await client.disconnect()
        }
    }

    struct DisconnectClearsSession {
        @Test
        func `handleDisconnect clears sessions and emits failed events`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Simulate receiving a session-initiate
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(200))

            // Collect events including the disconnect-triggered failure
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed = event { return true }
                    return false
                }
            }

            await client.disconnect()

            let events = try await eventsTask.value
            guard case let .jingleFileTransferFailed(sid, reason) = events.last else {
                Issue.record("Expected jingleFileTransferFailed event on disconnect")
                return
            }
            #expect(sid == "sid-123")
            #expect(reason == "disconnected")
        }
    }

    struct SessionInitiateWithSendersResponder {
        @Test
        func `Emits jingleFileRequestReceived when senders is responder`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileRequestReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(sessionInitiateXML(senders: "responder"))

            let events = try await eventsTask.value
            guard case let .jingleFileRequestReceived(request) = events.last else {
                Issue.record("Expected jingleFileRequestReceived event")
                await client.disconnect()
                return
            }
            #expect(request.sid == "sid-123")
            #expect(request.fileDescription.name == "test.txt")
            #expect(request.from.description == "peer@example.com/res")

            await client.disconnect()
        }
    }

    struct SessionInitiateWithSendersInitiator {
        @Test
        func `Emits jingleFileTransferReceived when senders is initiator`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(sessionInitiateXML(senders: "initiator"))

            let events = try await eventsTask.value
            guard case let .jingleFileTransferReceived(offer) = events.last else {
                Issue.record("Expected jingleFileTransferReceived event")
                await client.disconnect()
                return
            }
            #expect(offer.sid == "sid-123")

            await client.disconnect()
        }
    }

    struct SessionInitiateWithoutSenders {
        @Test
        func `Emits jingleFileTransferReceived when senders absent (defaults to both)`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(sessionInitiateXML())

            let events = try await eventsTask.value
            guard case .jingleFileTransferReceived = events.last else {
                Issue.record("Expected jingleFileTransferReceived event")
                await client.disconnect()
                return
            }

            await client.disconnect()
        }
    }

    struct SessionInfoChecksum {
        @Test
        func `Emits jingleChecksumReceived on session-info with checksum`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleChecksumReceived = event { return true }
                    return false
                }
            }

            // Create a session first
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(100))

            // Send session-info with checksum
            await mock.simulateReceive(sessionInfoChecksumXML(hash: "dGVzdA=="))

            let events = try await eventsTask.value
            guard case let .jingleChecksumReceived(sid, checksum) = events.last else {
                Issue.record("Expected jingleChecksumReceived event")
                await client.disconnect()
                return
            }
            #expect(sid == "sid-123")
            #expect(checksum.algo == "sha-256")
            #expect(checksum.hash == "dGVzdA==")
            #expect(checksum.contentName == "a-file-offer")

            await client.disconnect()
        }
    }

    struct VerifyChecksumMatch {
        @Test
        func `verifyChecksum returns true when no checksum pending`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))

            let result = module.verifyChecksum(sid: "nonexistent", receivedData: [1, 2, 3])
            #expect(result == true)

            await client.disconnect()
        }
    }
}
