import Foundation
import Network
import Synchronization

/// ``NWConnection``-backed transport.
///
/// TLS upgrade is implemented via cancel-and-reconnect since `NWConnection`
/// cannot upgrade an existing connection in-place.
actor NWConnectionTransport: XMPPTransport {
    private var connection: NWConnection?
    private nonisolated let queue = DispatchQueue(label: "ducko.transport", qos: .userInitiated)
    private var host: String?
    private var port: UInt16?

    /// Set during TLS upgrade to prevent the old connection's receive callback
    /// from finishing the shared `receivedData` stream.
    private nonisolated let isUpgrading = Atomic<Bool>(false)

    nonisolated let receivedData: AsyncStream<[UInt8]>
    private nonisolated let receivedContinuation: AsyncStream<[UInt8]>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        self.receivedData = stream
        self.receivedContinuation = continuation
    }

    func connect(host: String, port: UInt16) async throws {
        guard connection == nil else {
            throw XMPPConnectionError.alreadyConnected
        }
        self.host = host
        self.port = port

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)

        try await startConnection(conn)
    }

    func upgradeTLS(serverName: String) async throws {
        guard let conn = connection, let host, let port else {
            throw XMPPConnectionError.notConnected
        }

        // Prevent the old connection's receive callback from finishing the stream
        isUpgrading.store(true, ordering: .releasing)

        // Cancel the existing plain-text connection
        conn.cancel()
        connection = nil

        // Create a new connection with TLS
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, serverName)

        let params = NWParameters(tls: tlsOptions, tcp: .init())
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let tlsConn = NWConnection(host: nwHost, port: nwPort, using: params)

        do {
            try await startConnection(tlsConn)
            isUpgrading.store(false, ordering: .releasing)
        } catch {
            isUpgrading.store(false, ordering: .releasing)
            throw XMPPConnectionError.tlsUpgradeFailed("\(error)")
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard let conn = connection else {
            throw XMPPConnectionError.notConnected
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            conn.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: XMPPConnectionError.sendFailed("\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        receivedContinuation.finish()
    }

    // MARK: - Private

    private func startConnection(_ conn: NWConnection) async throws {
        let stateStream = AsyncThrowingStream<Void, any Error> { continuation in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.finish()
                case let .failed(error):
                    continuation.finish(
                        throwing: XMPPConnectionError.connectionFailed("\(error)")
                    )
                case .cancelled:
                    continuation.finish(throwing: XMPPConnectionError.connectionCancelled)
                default:
                    break
                }
            }
        }

        conn.start(queue: queue)
        for try await _ in stateStream {}

        connection = conn
        conn.stateUpdateHandler = nil
        scheduleReceive(conn)
    }

    private nonisolated func scheduleReceive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [receivedContinuation] content, _, isComplete, error in
            if let content, !content.isEmpty {
                receivedContinuation.yield(Array(content))
            }
            if isComplete || error != nil {
                if !self.isUpgrading.load(ordering: .acquiring) {
                    receivedContinuation.finish()
                }
                return
            }
            self.scheduleReceive(conn)
        }
    }
}
