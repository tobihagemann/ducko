import DuckoTestSupport

// MARK: - Handshake Simulation

// The stream-open and features constants used below live in `DuckoTestSupport/HandshakeFixtures.swift`
// (shared with DuckoXMPPTests). `testBindResult` stays per-target because its bound JID differs.

/// Bind result with a full JID.
let testBindResult = """
<iq type='result' id='ducko-1'>\
<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>\
<jid>alice@example.com/ducko</jid>\
</bind>\
</iq>
"""

/// Simulates a connect handshake without TLS.
func simulateNoTLSConnect(_ transport: MockTransport) async {
    await transport.waitForSent(count: 1) // stream opening sent
    await transport.simulateReceive(testServerStreamOpen)
    await transport.simulateReceive(testFeaturesNoTLS)
    await transport.waitForSent(count: 2) // auth element sent
    await transport.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    await transport.waitForSent(count: 3) // post-auth stream opening sent
    await transport.simulateReceive(testServerStreamOpen)
    await transport.simulateReceive(testFeaturesBind)
    await transport.waitForSent(count: 4) // bind IQ sent
    await transport.simulateReceive(testBindResult)
}
