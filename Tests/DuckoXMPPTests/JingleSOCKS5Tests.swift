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
        transport: mock
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

            // The transport-info should be processed without errors
            // (No crash, no unhandled case)
            await client.disconnect()
        }
    }

    struct TransportInfoCandidateError {
        @Test
        func `Emits jingleFileTransferFailed on candidate-error`() async throws {
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

            // Send transport-info with candidate-error
            await mock.simulateReceive(transportInfoCandidateErrorXML())

            let events = try await eventsTask.value
            guard case let .jingleFileTransferFailed(sid, reason) = events.last else {
                Issue.record("Expected jingleFileTransferFailed event")
                await client.disconnect()
                return
            }
            #expect(sid == "sid-123")
            #expect(reason == "candidate-error")

            await client.disconnect()
        }
    }

    struct ProxyActivationIQ {
        @Test
        func `Proxy activation IQ has correct structure`() {
            // Verify the proxy activation IQ would have the right namespace and elements
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
