/// Abstracts the network transport for testability.
public protocol XMPPTransport: Sendable {
    func connect(host: String, port: UInt16) async throws
    func connectWithTLS(host: String, port: UInt16, serverName: String) async throws

    /// Ends the current receive phase. No further bytes are yielded and the current receive stream finishes, so a consumer
    /// drains what is buffered and then ends. In-flight writes complete before it returns, so none overlaps a following
    /// TLS handshake.
    func stopReceiving() async

    /// Upgrades the connection to TLS in place and returns the TLS phase's receive stream. Requires a prior
    /// `stopReceiving()`.
    func upgradeTLS(serverName: String) async throws -> AsyncStream<[UInt8]>

    var tlsInfo: TLSInfo? { get async }

    /// Once accepted, bytes remain ordered even if the caller is cancelled: a stanza may already be counted for resumption.
    /// Completion is bounded by the write deadline or connection teardown.
    func send(_ bytes: [UInt8]) async throws

    /// The receive stream for the phase that `connect` or `connectWithTLS` starts.
    var receivedData: AsyncStream<[UInt8]> { get }

    /// Closes the connection and finishes whichever phase's receive stream is current.
    func disconnect() async

    /// Returns `tls-server-end-point` channel binding data (RFC 5929).
    /// Returns `nil` if TLS is not active or channel binding is not supported.
    func channelBindingData() async -> [UInt8]?
}

public extension XMPPTransport {
    var tlsInfo: TLSInfo? {
        get async { nil }
    }

    func channelBindingData() async -> [UInt8]? {
        nil
    }
}
