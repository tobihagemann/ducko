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

/// Builds a transport-info IQ with a SOCKS5 candidate-error.
private func candidateErrorXML(
    id: String = "ti-error-1",
    sid: String = "sid-ibb-test",
    from: String = "peer@example.com/res"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>\
    <content creator='initiator' name='a-file-offer'>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='transport-sid'><candidate-error/></transport>\
    </content>\
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

            await disconnectFast(client)
        }
    }

    struct TransportRejectEmitsFailure {
        @Test
        func `Receiving transport-reject emits a failure event and fails later transport waits`() async throws {
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
                await disconnectFast(client)
                return
            }
            #expect(sid == "sid-ibb-test")
            #expect(reason == .transportReject)
            let terminateSent = try await boundedOutcome {
                _ = await mock.waitForSent { $0.contains("session-terminate") && $0.contains("failed-transport") }
            }
            #expect(terminateSent != nil)

            let module = try #require(await client.module(ofType: JingleModule.self))
            let outcome = try await boundedOutcome { try await module.awaitTransportReady(sid: "sid-ibb-test") }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the wait to fail, got \(String(describing: outcome))")
                await disconnectFast(client)
                return
            }
            #expect(error as? JingleModule.JingleError == .sessionNotFound)

            await disconnectFast(client)
        }
    }

    struct TransportReplaceSendFailure {
        @Test
        func `A transport-replace that fails to send abandons the transport`() async throws {
            let harness = JingleInitiatorHarness(failingActions: [JingleAction.transportReplace.rawValue])
            let sid = try await harness.initiate()

            try harness.receive(action: "transport-info", sid: sid, payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))])
            let failure = try await harness.event { event in
                if case .jingleFileTransferFailed(_, .transportReplaceFailed) = event { return true }
                return false
            }
            #expect(failure != nil)
            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "failed-transport") != nil)

            // The failed proposal already installed IBB state, so only removing the abandoned session can fail this wait.
            let outcome = try await boundedOutcome { try await harness.module.awaitTransportReady(sid: sid) }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the wait to fail, got \(String(describing: outcome))")
                return
            }
            #expect(error as? JingleModule.JingleError == .sessionNotFound)
        }
    }

    struct AbandonedIBBTransfer {
        @Test
        func `Abandoning a transport ends a pending IBB receive and ignores a later close`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))

            await mock.simulateReceive(sessionInitiateXML())
            await mock.simulateReceive(transportReplaceXML())
            _ = await mock.waitForSent { $0.contains("transport-accept") }
            let receiveTask = Task { try await module.receiveFileData(sid: "sid-ibb-test", expectedSize: 1024) }
            try await Task.sleep(for: .milliseconds(100))

            let rejected = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(transportRejectXML())
            _ = try await rejected.value

            let outcome = try await boundedOutcome { _ = try await receiveTask.value }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the receive to fail, got \(String(describing: outcome))")
                await disconnectFast(client)
                return
            }
            #expect(error as? JingleModule.JingleError == .transportNegotiationFailed("The peer rejected the connection method"))

            // The offer that follows the close marks the point by which a completion would have been reported.
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(ibbCloseXML())
            await mock.simulateReceive(sessionInitiateXML(id: "jingle-2", sid: "sid-next"))
            let events = try await eventsTask.value
            #expect(!events.contains { if case .jingleFileTransferCompleted = $0 { true } else { false } })
            await disconnectFast(client)
        }

        @Test
        func `A transport-replace with an invalid block size is rejected`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.simulateReceive(sessionInitiateXML())
            await mock.simulateReceive(transportReplaceXML(blockSize: 0))
            let rejectSent = try await boundedOutcome {
                _ = await mock.waitForSent { $0.contains("transport-reject") }
            }
            #expect(rejectSent != nil)
            let sent = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent.contains { $0.contains("transport-accept") })
            await disconnectFast(client)
        }
    }

    struct DisconnectAfterAbandon {
        @Test
        func `A disconnect reports no second failure for an abandoned transport`() async throws {
            let harness = JingleInitiatorHarness(failingActions: [JingleAction.transportReplace.rawValue])
            let abandonedSID = try await harness.initiate()
            let liveSID = try await harness.initiate()
            try harness.receive(
                action: "transport-info", sid: abandonedSID, payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))]
            )
            let abandoned = try await harness.event { event in
                if case .jingleFileTransferFailed(abandonedSID, .transportReplaceFailed) = event { return true }
                return false
            }
            #expect(abandoned != nil)

            await harness.module.handleDisconnect()
            // The live session's failure shows the disconnect reported failures at all.
            let live = try await harness.event { event in
                if case .jingleFileTransferFailed(liveSID, .disconnected) = event { return true }
                return false
            }
            #expect(live != nil)
            let repeated = try await harness.event(timeout: .zero) { event in
                if case .jingleFileTransferFailed(abandonedSID, .disconnected) = event { return true }
                return false
            }
            #expect(repeated == nil)
        }
    }

    struct TransportWaitAfterFallback {
        @Test
        func `A transport wait after IBB fallback is established resolves at once`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))

            await mock.simulateReceive(sessionInitiateXML())
            await mock.simulateReceive(transportReplaceXML())
            _ = await mock.waitForSent { $0.contains("transport-accept") }

            let outcome = try await boundedOutcome { try await module.awaitTransportReady(sid: "sid-ibb-test") }
            guard case .success? = outcome else {
                Issue.record("Expected the wait to resolve, got \(String(describing: outcome))")
                await disconnectFast(client)
                return
            }
            await disconnectFast(client)
        }
    }

    struct StaleCandidateError {
        @Test
        func `A candidate-error after IBB fallback reports no failure`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferCompleted = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(sessionInitiateXML())
            await mock.simulateReceive(transportReplaceXML())
            _ = await mock.waitForSent { $0.contains("transport-accept") }
            // The initiator's own SOCKS5 attempt fails after it already switched to IBB.
            await mock.simulateReceive(candidateErrorXML())
            await mock.simulateReceive(ibbCloseXML())

            let events = try await eventsTask.value
            #expect(!events.contains { if case .jingleFileTransferFailed = $0 { true } else { false } })
            await disconnectFast(client)
        }

        @Test
        func `A candidate-error for an unknown session reports no failure`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // The offer that follows the candidate-error marks the point by which a failure would have been reported.
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(candidateErrorXML(sid: "ended-sid"))
            await mock.simulateReceive(sessionInitiateXML())

            let events = try await eventsTask.value
            #expect(!events.contains { if case .jingleFileTransferFailed = $0 { true } else { false } })
            await disconnectFast(client)
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

            await disconnectFast(client)
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
                await disconnectFast(client)
                return
            }
            #expect(sid == "sid-ibb-test")
            #expect(transport == .ibb)

            await disconnectFast(client)
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

            await disconnectFast(client)

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
