/// Abstracts the network transport for testability.
public protocol XMPPTransport: Sendable {
    func connect(host: String, port: UInt16) async throws
    func connectWithTLS(host: String, port: UInt16, serverName: String) async throws
    func upgradeTLS(serverName: String) async throws
    func send(_ bytes: [UInt8]) async throws
    var receivedData: AsyncStream<[UInt8]> { get }
    func disconnect() async

    /// Returns `tls-server-end-point` channel binding data (RFC 5929).
    /// Returns `nil` if TLS is not active or channel binding is not supported.
    func channelBindingData() async -> [UInt8]?
}

public extension XMPPTransport {
    func channelBindingData() async -> [UInt8]? {
        nil
    }
}
