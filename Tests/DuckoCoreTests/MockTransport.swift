@testable import DuckoXMPP

/// Minimal mock transport for AccountService tests.
actor MockTransport: XMPPTransport {
    nonisolated let receivedData: AsyncStream<[UInt8]>
    private let receivedContinuation: AsyncStream<[UInt8]>.Continuation
    private(set) var sentBytes: [[UInt8]] = []
    private(set) var isConnected = false

    private let connectError: (any Error)?
    private var sentWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(connectError: (any Error)? = nil) {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        self.receivedData = stream
        self.receivedContinuation = continuation
        self.connectError = connectError
    }

    func connect(host: String, port: UInt16) async throws {
        if let connectError {
            throw connectError
        }
        guard !isConnected else {
            throw XMPPConnectionError.alreadyConnected
        }
        isConnected = true
    }

    func upgradeTLS(serverName: String) async throws {
        guard isConnected else {
            throw XMPPConnectionError.notConnected
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard isConnected else {
            throw XMPPConnectionError.notConnected
        }
        sentBytes.append(bytes)
        if let waiter = sentWaiters.removeValue(forKey: sentBytes.count) {
            waiter.resume()
        }
    }

    func disconnect() {
        isConnected = false
        receivedContinuation.finish()
    }

    // MARK: - Test Helpers

    func waitForSent(count: Int) async {
        if sentBytes.count >= count { return }
        await withCheckedContinuation { continuation in
            sentWaiters[count] = continuation
        }
    }

    func simulateReceive(_ string: String) {
        receivedContinuation.yield(Array(string.utf8))
    }
}

// MARK: - Handshake Simulation

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
