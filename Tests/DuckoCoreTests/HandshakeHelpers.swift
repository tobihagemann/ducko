import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing

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

/// Drives a full mock handshake for an already-loaded account until its client reaches `.connected`, returning
/// the connected client and the still-running connect task (cancel it and `disconnect` during teardown). Set
/// `awaitInitialPresence` when the test inspects sent presence — it waits for the initial available presence and
/// entity caps to flush so a later `clearSentBytes()` can't race those still-in-flight stanzas (requires the
/// factory to register `PresenceModule` + `CapsModule`). Consolidates the connect-and-poll setup the presence
/// suites repeat.
@MainActor
func driveMockConnect(
    _ service: AccountService,
    accountID: UUID,
    password: String = "secret",
    transport: MockTransport,
    awaitInitialPresence: Bool = false
) async throws -> (client: XMPPClient, task: Task<Void, any Error>) {
    let task = Task { @MainActor in
        try await service.connect(accountID: accountID, password: password)
    }
    await simulateNoTLSConnect(transport)
    if awaitInitialPresence {
        // The handshake sends 4 stanzas through bind; the client then sends the initial available presence
        // (stanza 5) and entity caps (stanza 6), so a cumulative count of 6 means both have flushed.
        await transport.waitForSent(count: 6)
    }
    for _ in 0 ..< 100 {
        if service.connectedClient(for: accountID) != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let client = try #require(service.connectedClient(for: accountID))
    return (client, task)
}
