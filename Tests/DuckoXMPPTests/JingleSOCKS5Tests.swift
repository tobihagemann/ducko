import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private struct TestCandidate {
    let cid: String
    let host: String
    let port: UInt16
    let jid: String
    let priority: UInt32
    let type: String
}

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

/// Builds a session-initiate IQ XML with SOCKS5 transport candidates.
private func sessionInitiateWithCandidatesXML(
    id: String = "jingle-1",
    sid: String = "sid-123",
    from: String = "peer@example.com/res",
    transportSID: String = "transport-sid",
    candidates: [TestCandidate] = []
) -> String {
    let candidateXML = candidates.map { c in
        "<candidate cid='\(c.cid)' host='\(c.host)' port='\(c.port)' jid='\(c.jid)' priority='\(c.priority)' type='\(c.type)'/>"
    }.joined()
    return """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='\(sid)' initiator='\(from)'>\
    <content creator='initiator' name='a-file-offer'>\
    <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>\
    <file>\
    <name>test.txt</name>\
    <size>1024</size>\
    </file>\
    </description>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='\(transportSID)'>\
    \(candidateXML)\
    </transport>\
    </content>\
    </jingle>\
    </iq>
    """
}

/// Builds a transport-info IQ XML with candidate-used.
private func transportInfoCandidateUsedXML(
    id: String = "ti-1",
    sid: String = "sid-123",
    from: String = "peer@example.com/res",
    transportSID: String = "transport-sid",
    cid: String = "proxy-1"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>\
    <content creator='initiator' name='a-file-offer'>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='\(transportSID)'>\
    <candidate-used cid='\(cid)'/>\
    </transport>\
    </content>\
    </jingle>\
    </iq>
    """
}

/// Builds a transport-info IQ XML with candidate-error.
private func transportInfoCandidateErrorXML(
    id: String = "ti-2",
    sid: String = "sid-123",
    from: String = "peer@example.com/res",
    transportSID: String = "transport-sid"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>\
    <content creator='initiator' name='a-file-offer'>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='\(transportSID)'>\
    <candidate-error/>\
    </transport>\
    </content>\
    </jingle>\
    </iq>
    """
}

// MARK: - Tests

enum JingleSOCKS5Tests {
    struct TransportInfoCandidateUsed {
        @Test
        func `Handles transport-info with candidate-used`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Create session via session-initiate
            let initXML = sessionInitiateWithCandidatesXML(
                candidates: [TestCandidate(cid: "proxy-1", host: "proxy.example.com", port: 1080, jid: "proxy@example.com", priority: 10, type: "proxy")]
            )
            await mock.simulateReceive(initXML)
            try? await Task.sleep(for: .milliseconds(200))

            // Accept the session (as responder)
            let module = try #require(await client.module(ofType: JingleModule.self))
            try await module.acceptFileTransfer(sid: "sid-123")
            try? await Task.sleep(for: .milliseconds(100))

            // Now send transport-info with candidate-used from peer
            await mock.simulateReceive(transportInfoCandidateUsedXML(cid: "proxy-1"))
            try? await Task.sleep(for: .milliseconds(100))

            // Only the initiator activates a proxy, so the responder sends no activation when the peer reports a used candidate.
            let sent = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent.contains { $0.contains("<activate") })
            await disconnectFast(client)
        }
    }

    struct TransportInfoCandidateError {
        @Test
        func `A responder reports no failure for the initiator's candidate-error`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Create session via session-initiate
            await mock.simulateReceive(sessionInitiateWithCandidatesXML())
            try? await Task.sleep(for: .milliseconds(200))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed = event { return true }
                    return false
                }
            }

            // The initiator's candidate-error leaves the outcome to what it sends next, here a session-terminate.
            await mock.simulateReceive(transportInfoCandidateErrorXML())
            await mock.simulateReceive(
                "<iq type='set' id='terminate-1' from='peer@example.com/res'><jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='sid-123'><reason><failed-transport/></reason></jingle></iq>"
            )

            let events = try await eventsTask.value
            guard case let .jingleFileTransferFailed(sid, reason) = events.last else {
                Issue.record("Expected jingleFileTransferFailed event")
                await disconnectFast(client)
                return
            }
            #expect(sid == "sid-123")
            #expect(reason == .failedTransport)

            await disconnectFast(client)
        }
    }

    struct InitiatorSOCKS5Outcomes {
        private static let proxyJID = "proxy.example.com"

        /// Answers proxy discovery with one Proxy65 service whose activation fails.
        private static func answerWithFailingProxy(_ iq: XMLElement) throws -> XMLElement? {
            guard let query = iq.child(named: "query") else { return nil }
            var answer = XMLElement(name: "query", namespace: query.namespace)
            switch query.namespace {
            case XMPPNamespaces.discoItems:
                answer.addChild(XMLElement(name: "item", attributes: ["jid": proxyJID]))
            case XMPPNamespaces.discoInfo:
                answer.addChild(XMLElement(name: "feature", attributes: ["var": XMPPNamespaces.bytestreams]))
            case XMPPNamespaces.bytestreams:
                if query.child(named: "activate") != nil {
                    throw XMPPStanzaError(errorType: .cancel, condition: .itemNotFound)
                }
                answer.addChild(XMLElement(name: "streamhost", attributes: ["jid": proxyJID, "host": "192.0.2.1", "port": "7777"]))
            default:
                return nil
            }
            return answer
        }

        private static func candidateError() -> XMLElement {
            JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))
        }

        private static func candidateUsed(_ candidate: XMLElement) throws -> XMLElement {
            let cid = try #require(candidate.attribute("cid"))
            return JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-used", attributes: ["cid": cid]))
        }

        private static func isActivation(_ iq: XMLElement) -> Bool {
            iq.child(named: "query")?.child(named: "activate") != nil
        }

        private static func isFailedTransportTerminate(_ stanza: XMLElement?) -> Bool {
            stanza?.child(named: "jingle")?.child(named: "reason")?.child(named: "failed-transport") != nil
        }

        /// Starts a session whose SOCKS5 attempt is inside this side's listener accept, proven by a probe that holds a
        /// handshake open.
        private static func startAttempt(_ harness: JingleInitiatorHarness) async throws -> (sid: String, probe: SOCKS5GreetingProbe) {
            let sid = try await harness.initiate()
            let direct = try harness.offeredCandidate(type: "direct")
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            let probe = try #require(SOCKS5GreetingProbe(candidate: direct))
            try #require(probe.awaitReply())
            return (sid, probe)
        }

        @Test
        func `An initiator reports its SOCKS5 failure while the attempt is current`() async throws {
            let harness = JingleInitiatorHarness()
            let (sid, probe) = try await Self.startAttempt(harness)

            // The peer's direct candidate-used closes the listener without switching transports, which ends the attempt as a failure.
            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateUsed(harness.offeredCandidate(type: "direct"))])
            #expect(try await harness.sentJingle(action: JingleAction.transportInfo.rawValue) != nil)
            withExtendedLifetime(probe) {}
        }

        @Test
        func `An initiator ignores its SOCKS5 failure after switching to IBB`() async throws {
            let harness = JingleInitiatorHarness()
            let (sid, probe) = try await Self.startAttempt(harness)

            // The peer's candidate-error switches this side to IBB and closes the listener its attempt waits on.
            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateError()])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)
            #expect(try await harness.sentJingle(action: JingleAction.transportInfo.rawValue, timeout: .seconds(1)) == nil)
            withExtendedLifetime(probe) {}
        }

        @Test
        func `A repeated session-accept does not start a second SOCKS5 attempt`() async throws {
            let harness = JingleInitiatorHarness()
            let (sid, probe) = try await Self.startAttempt(harness)

            // A second attempt would find the listener busy and report a failure while the first one still runs.
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            #expect(try await harness.sentJingle(action: JingleAction.transportInfo.rawValue, timeout: .seconds(1)) == nil)
            withExtendedLifetime(probe) {}
        }

        @Test
        func `A repeated candidate-error proposes IBB only once`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.initiate()

            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateError()])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)
            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateError()])
            try await Task.sleep(for: .milliseconds(300))
            #expect(harness.sentJingleCount(action: JingleAction.transportReplace.rawValue) == 1)
        }

        @Test
        func `Adding a file keeps the primary content's listener`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.initiate()
            let direct = try harness.offeredCandidate(type: "direct")
            _ = try await harness.module.sendContentAdd(sid: sid, file: JingleFileDescription(name: "second.txt", size: 3))

            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            let probe = try #require(SOCKS5GreetingProbe(candidate: direct))
            #expect(probe.awaitReply())
        }

        @Test
        func `Ending a session closes only its own added files' listeners`() async throws {
            // Both sessions share one module's listeners. A listener queues one pending connection, so each added file's
            // listener is probed only once.
            let harness = JingleInitiatorHarness()
            let endedSID = try await harness.initiate()
            let liveSID = try await harness.initiate()
            _ = try await harness.module.sendContentAdd(sid: endedSID, file: JingleFileDescription(name: "second.txt", size: 3))
            _ = try await harness.module.sendContentAdd(sid: liveSID, file: JingleFileDescription(name: "second.txt", size: 3))
            let contentAdd = JingleAction.contentAdd.rawValue
            let ended = try harness.offeredCandidate(type: "direct", action: contentAdd, sid: endedSID)
            let live = try harness.offeredCandidate(type: "direct", action: contentAdd, sid: liveSID)

            try await harness.module.terminateSession(sid: endedSID, reason: .cancel)
            #expect(SOCKS5GreetingProbe(candidate: ended) == nil)
            // The other session still accepts connections on its added file's listener.
            #expect(SOCKS5GreetingProbe(candidate: live) != nil)
        }

        @Test
        func `A proxy activation failure abandons the transport`() async throws {
            let harness = JingleInitiatorHarness(answerIQ: Self.answerWithFailingProxy)
            let sid = try await harness.initiate()

            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateUsed(harness.offeredCandidate(type: "proxy"))])
            let failure = try await harness.event { event in
                if case .jingleFileTransferFailed(_, .proxyActivationFailed) = event { return true }
                return false
            }
            #expect(failure != nil)
            #expect(try await Self.isFailedTransportTerminate(harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)))

            let outcome = try await boundedOutcome { try await harness.module.awaitTransportReady(sid: sid) }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the wait to fail, got \(String(describing: outcome))")
                return
            }
            #expect(error as? JingleModule.JingleError == .sessionNotFound)

            // The abandoned negotiation stays closed to a late candidate-error.
            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateError()])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue, timeout: .seconds(1)) == nil)
        }

        @Test
        func `An abandoned session accepts no further actions`() async throws {
            let harness = JingleInitiatorHarness(answerIQ: Self.answerWithFailingProxy)
            let sid = try await harness.initiate()
            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateUsed(harness.offeredCandidate(type: "proxy"))])
            #expect(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue) != nil)

            // A send finishing now can't end the session as a success, and nothing can be added to it.
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                try await harness.module.terminateSession(sid: sid, reason: .success)
            }
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                _ = try await harness.module.sendContentAdd(sid: sid, file: JingleFileDescription(name: "second.txt", size: 3))
            }
            #expect(harness.sentJingleCount(action: JingleAction.sessionTerminate.rawValue) == 1)
        }

        @Test
        func `Abandoning a transport closes its listener`() async throws {
            let harness = JingleInitiatorHarness(answerIQ: Self.answerWithFailingProxy)
            let (sid, probe) = try await Self.startAttempt(harness)

            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateUsed(harness.offeredCandidate(type: "proxy"))])
            // Closing the listener ends the handshake the probe holds open.
            #expect(probe.awaitClosed())
        }

        @Test
        func `A proxy candidate used after switching to IBB is not activated`() async throws {
            let harness = JingleInitiatorHarness(answerIQ: Self.answerWithFailingProxy)
            let sid = try await harness.initiate()

            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateError()])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)
            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateUsed(harness.offeredCandidate(type: "proxy"))])

            let activation = try await harness.sentIQ(timeout: .seconds(1), matching: Self.isActivation)
            #expect(activation == nil)
            let failure = try await harness.event(timeout: .milliseconds(100)) { event in
                if case .jingleFileTransferFailed = event { return true }
                return false
            }
            #expect(failure == nil)
        }

        @Test
        func `A proxy activation that fails after switching to IBB leaves the fallback in place`() async throws {
            let activationGate = AsyncSemaphore()
            let harness = JingleInitiatorHarness { iq in
                if Self.isActivation(iq) {
                    await activationGate.wait()
                }
                return try Self.answerWithFailingProxy(iq)
            }
            let sid = try await harness.initiate()

            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateUsed(harness.offeredCandidate(type: "proxy"))])
            #expect(try await harness.sentIQ(matching: Self.isActivation) != nil)
            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateError()])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)

            await activationGate.signal()
            let failure = try await harness.event(timeout: .seconds(1)) { event in
                if case .jingleFileTransferFailed = event { return true }
                return false
            }
            #expect(failure == nil)
            #expect(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue, timeout: .milliseconds(100)) == nil)
        }
    }

    struct ProxyActivationIQ {
        @Test
        func `Proxy activation IQ has correct structure`() {
            var query = XMLElement(name: "query", namespace: XMPPNamespaces.bytestreams, attributes: ["sid": "transport-sid"])
            var activate = XMLElement(name: "activate")
            activate.addText("target@example.com/res")
            query.addChild(activate)

            #expect(query.namespace == XMPPNamespaces.bytestreams)
            #expect(query.attribute("sid") == "transport-sid")

            let activateChild = query.child(named: "activate")
            #expect(activateChild != nil)
            #expect(activateChild?.textContent == "target@example.com/res")
        }
    }

    struct TransportState {
        @Test
        func `TransportState.pending is default`() throws {
            let bareJID = try #require(BareJID(localPart: "user", domainPart: "example.com"))
            let peer = try #require(FullJID(bareJID: bareJID, resourcePart: "res"))
            let desc = JingleFileDescription(name: "f.txt", size: 100)
            let transport = JingleTransportDescription.socks5(SOCKS5Transport(sid: "t-1"))
            let content = JingleContent(name: "offer", creator: "initiator", description: desc, transport: transport)
            let session = JingleSession(peer: peer, role: .initiator, content: content)

            if case .pending = session.transportState {
                // Expected
            } else {
                Issue.record("Expected .pending transport state")
            }
        }
    }
}
