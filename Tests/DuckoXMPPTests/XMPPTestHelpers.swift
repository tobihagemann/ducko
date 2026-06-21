import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - XML Constants

// `testServerStreamOpen`, `testFeaturesNoTLS`, and `testFeaturesBind` live in
// `DuckoTestSupport/HandshakeFixtures.swift` (shared with DuckoCoreTests). The SM/SASL2/ISR constants below
// are XMPP-only, so they stay here.

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

// MARK: - Disconnect

/// Disconnects with a short stream-close timeout so teardown doesn't pay the production fallback while waiting
/// for a server `</stream:stream>` reply the test never injects. Use wherever `disconnect()` is just cleanup;
/// tests that exercise the happy-path reply or pin disconnect ordering drive the timeout themselves.
func disconnectFast(_ client: XMPPClient) async {
    await client.disconnect(streamCloseTimeout: .milliseconds(20))
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

// MARK: - SASL2 Constants

/// Features offering SASL2 with PLAIN and inline Bind 2 + SM.
/// Uses PLAIN only for simpler test handshakes (no challenge/response needed).
let testFeaturesSASL2 = """
<features xmlns='http://etherx.jabber.org/streams'>\
<authentication xmlns='urn:xmpp:sasl:2'>\
<mechanism>PLAIN</mechanism>\
<inline>\
<bind xmlns='urn:xmpp:bind:0'/>\
<sm xmlns='urn:xmpp:sm:3'/>\
</inline>\
</authentication>\
</features>
"""

/// SASL2 success with Bind 2 and inline SM enabled.
let testSASL2SuccessWithBind = """
<success xmlns='urn:xmpp:sasl:2'>\
<authorization-identifier>user@example.com/ducko</authorization-identifier>\
<bound xmlns='urn:xmpp:bind:0'>\
<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-1' max='300'/>\
</bound>\
</success>
"""

/// Post-auth features after SASL2 (bind already done, only informational).
let testPostSASL2Features = """
<features xmlns='http://etherx.jabber.org/streams'>\
<sm xmlns='urn:xmpp:sm:3'/>\
</features>
"""

/// Simulates a SASL2 + Bind 2 connect handshake using PLAIN mechanism.
func simulateSASL2Connect(_ mock: MockTransport) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesSASL2)
    await mock.waitForSent(count: 2) // <authenticate> with inline bind2 sent
    await mock.simulateReceive(testSASL2SuccessWithBind)
    await mock.waitForSent(count: 3) // post-auth stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testPostSASL2Features)
}

// MARK: - ISR Constants

/// SASL2 features with ISR support in inline.
let testFeaturesSASL2WithISR = """
<features xmlns='http://etherx.jabber.org/streams'>\
<authentication xmlns='urn:xmpp:sasl:2'>\
<mechanism>PLAIN</mechanism>\
<inline>\
<bind xmlns='urn:xmpp:bind:0'/>\
<sm xmlns='urn:xmpp:sm:3'/>\
<isr xmlns='https://xmpp.org/extensions/isr/0'/>\
</inline>\
</authentication>\
</features>
"""

/// SASL2 success with Bind 2, inline SM enabled, and ISR token.
let testSASL2SuccessWithBindAndISR = """
<success xmlns='urn:xmpp:sasl:2'>\
<authorization-identifier>user@example.com/ducko</authorization-identifier>\
<bound xmlns='urn:xmpp:bind:0'>\
<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-1' max='300'>\
<isr-enabled xmlns='https://xmpp.org/extensions/isr/0' token='initial-isr-token' mechanism='HT-SHA-256-ENDP'/>\
</enabled>\
</bound>\
</success>
"""

/// ISR success: contains `<resumed>` instead of `<bound>`, plus refreshed token.
let testISRSuccess = """
<success xmlns='urn:xmpp:sasl:2'>\
<authorization-identifier>user@example.com/ducko</authorization-identifier>\
<resumed xmlns='urn:xmpp:sm:3' h='0' previd='sm-resume-1'/>\
<isr-enabled xmlns='https://xmpp.org/extensions/isr/0' token='refreshed-token' mechanism='HT-SHA-256-ENDP'/>\
</success>
"""

/// ISR failure (token expired).
let testISRFailure = """
<failure xmlns='urn:xmpp:sasl:2'>\
<credentials-expired/>\
</failure>
"""

/// Simulates a SASL2 + Bind 2 connect that acquires an ISR token.
func simulateSASL2ConnectWithISR(_ mock: MockTransport) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesSASL2WithISR)
    await mock.waitForSent(count: 2) // <authenticate> with inline bind2 sent
    await mock.simulateReceive(testSASL2SuccessWithBindAndISR)
    await mock.waitForSent(count: 3) // post-auth stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testPostSASL2Features)
}

/// Simulates an ISR resume connect (server responds with ISR success).
func simulateISRResumeConnect(_ mock: MockTransport) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesSASL2WithISR)
    await mock.waitForSent(count: 2) // ISR <authenticate> sent
    await mock.simulateReceive(testISRSuccess)
    await mock.waitForSent(count: 3) // post-auth stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testPostSASL2Features)
}

/// Simulates ISR failure followed by normal SASL2 fallback.
func simulateISRFailAndFallback(_ mock: MockTransport) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesSASL2WithISR)
    await mock.waitForSent(count: 2) // ISR <authenticate> sent
    await mock.simulateReceive(testISRFailure)
    await mock.waitForSent(count: 3) // normal SASL2 <authenticate> sent
    await mock.simulateReceive(testSASL2SuccessWithBind)
    await mock.waitForSent(count: 4) // post-auth stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testPostSASL2Features)
}

// MARK: - Sent-Response Waiting

/// Clears the mock's sent buffer, injects `stanza`, then suspends until an outgoing stanza satisfies
/// `predicate` or `timeout` elapses. Returns the matching string, or `nil` on timeout / no match.
///
/// The wait is event-driven: `MockTransport.waitForSent(matching:)` fires the instant a matching stanza is
/// sent (or finds one already buffered), raced against a timeout task. Actor isolation makes a match
/// deterministic regardless of scheduler load — only the `nil`/timeout path depends on the clock.
///
/// Call sites must not chain a second `simulateReceive` into the same `awaitSentResponse` invocation without
/// first awaiting the previous response to completion — a pending fire-and-forget reply from an earlier
/// stimulus could otherwise satisfy the new predicate and mask a missing response.
func awaitSentResponse(
    on mock: MockTransport,
    afterReceiving stanza: String,
    matching predicate: @escaping @Sendable (String) -> Bool,
    timeout: Duration = .seconds(2)
) async -> String? {
    await mock.clearSentBytes()

    return await withTaskGroup(of: String?.self) { group in
        group.addTask { await mock.waitForSent(matching: predicate) }
        // simulateReceive runs after the waiter task is scheduled; waitForSent scans the
        // already-sent buffer when it registers, so a reply that lands before the task
        // starts is still caught (no lost wakeup).
        await mock.simulateReceive(stanza)
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        for await result in group {
            group.cancelAll()
            return result
        }
        return nil
    }
}
