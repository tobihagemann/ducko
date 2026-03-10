import Testing
@testable import DuckoXMPP

// MARK: - XML Constants

/// Standard stream opening from server.
let testServerStreamOpen =
    "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='example.com' version='1.0'>"

/// Features offering only PLAIN auth (no TLS).
let testFeaturesNoTLS = """
<features xmlns='http://etherx.jabber.org/streams'>\
<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\
<mechanism>PLAIN</mechanism>\
</mechanisms>\
</features>
"""

/// Post-auth features with bind only.
let testFeaturesBind = """
<features xmlns='http://etherx.jabber.org/streams'>\
<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>\
</features>
"""

/// Post-auth features with bind and Stream Management.
let testFeaturesBindWithSM = """
<features xmlns='http://etherx.jabber.org/streams'>\
<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>\
<sm xmlns='urn:xmpp:sm:3'/>\
</features>
"""

/// Bind result with a full JID.
let testBindResult = """
<iq type='result' id='ducko-1'>\
<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>\
<jid>user@example.com/ducko</jid>\
</bind>\
</iq>
"""

// MARK: - Connect Flow Simulation

/// Simulates a connect handshake without TLS.
func simulateNoTLSConnect(_ mock: MockTransport, postAuthFeatures: String = testFeaturesBind) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesNoTLS)
    await mock.waitForSent(count: 2) // auth element sent
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    await mock.waitForSent(count: 3) // post-auth stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(postAuthFeatures)
    await mock.waitForSent(count: 4) // bind IQ sent
    await mock.simulateReceive(testBindResult)
}

/// Simulates a connect handshake without TLS, followed by a roster response.
func simulateNoTLSConnect(_ mock: MockTransport, rosterResponse: String) async {
    await simulateNoTLSConnect(mock)
    await mock.waitForSent(count: 5) // roster GET IQ sent
    await mock.simulateReceive(rosterResponse)
}

/// Simulates a direct TLS connect handshake (TLS already active, no STARTTLS negotiation).
func simulateDirectTLSConnect(_ mock: MockTransport, postAuthFeatures: String = testFeaturesBind) async {
    await simulateNoTLSConnect(mock, postAuthFeatures: postAuthFeatures)
}

// MARK: - Event Collection

/// Collects events until `predicate` returns `true`, with a timeout.
func collectEvents(
    from client: XMPPClient,
    timeout: Duration = .seconds(5),
    until predicate: @Sendable @escaping (XMPPEvent) -> Bool
) async throws -> [XMPPEvent] {
    try await withThrowingTaskGroup(of: [XMPPEvent].self) { group in
        group.addTask {
            var collected: [XMPPEvent] = []
            for await event in client.events {
                collected.append(event)
                if predicate(event) { break }
            }
            return collected
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw XMPPClientError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - IQ ID Extraction

/// Extracts the IQ `id` attribute value from a raw XML string.
func extractIQID(from xmlString: String) -> String? {
    guard let idRange = xmlString.range(of: "id=\""),
          let endRange = xmlString[idRange.upperBound...].firstIndex(of: "\"") else {
        return nil
    }
    return String(xmlString[idRange.upperBound ..< endRange])
}
