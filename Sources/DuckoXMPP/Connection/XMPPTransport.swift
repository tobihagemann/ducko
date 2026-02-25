/// Errors from XMPP connection operations.
enum XMPPConnectionError: Error, Sendable {
    case alreadyConnected
    case notConnected
    case connectionFailed(String)
    case tlsUpgradeFailed(String)
    case connectionTimeout
    case connectionCancelled
    case sendFailed(String)
}

/// Abstracts the network transport for testability.
protocol XMPPTransport: Sendable {
    func connect(host: String, port: UInt16) async throws
    func upgradeTLS(serverName: String) async throws
    func send(_ bytes: [UInt8]) async throws
    var receivedData: AsyncStream<[UInt8]> { get }
    func disconnect() async
}
