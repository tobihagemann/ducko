import DuckoXMPP

/// Shared in-memory ``XMPPTransport`` mock for both DuckoCoreTests and DuckoXMPPTests. Records sent bytes,
/// replays scripted server stanzas via ``simulateReceive(_:)``, and supports connect-error injection, send
/// failures, and send-blocking (to hold a specific stanza off the wire while a test observes gated behavior).
public actor MockTransport: XMPPTransport {
    public nonisolated let receivedData: AsyncStream<[UInt8]>
    private let receivedContinuation: AsyncStream<[UInt8]>.Continuation
    public private(set) var sentBytes: [[UInt8]] = []
    public private(set) var isConnected = false
    public private(set) var isTLSUpgraded = false
    public private(set) var connectedHost: String?
    public private(set) var connectedPort: UInt16?

    private let connectError: (any Error)?
    private var nextConnectError: (any Error)?
    private var sendFailure: (any Error)?
    private var sentWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var blockPredicate: (@Sendable (String) -> Bool)?
    private var blockedSends: [CheckedContinuation<Void, Never>] = []
    private var blockedReleased = false

    public init(connectError: (any Error)? = nil) {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        self.receivedData = stream
        self.receivedContinuation = continuation
        self.connectError = connectError
    }

    public func connect(host: String, port: UInt16) async throws {
        if let error = takeConnectError() {
            throw error
        }
        guard !isConnected else {
            throw MockTransportError.alreadyConnected
        }
        isConnected = true
        connectedHost = host
        connectedPort = port
    }

    public func connectWithTLS(host: String, port: UInt16, serverName: String) async throws {
        if let error = takeConnectError() {
            throw error
        }
        guard !isConnected else {
            throw MockTransportError.alreadyConnected
        }
        isConnected = true
        isTLSUpgraded = true
        connectedHost = host
        connectedPort = port
    }

    /// Resolves the error (if any) the current connect attempt should throw. The permanent
    /// `init(connectError:)` error takes precedence and is never consumed.
    private func takeConnectError() -> (any Error)? {
        if let connectError {
            return connectError
        }
        let next = nextConnectError
        nextConnectError = nil
        return next
    }

    public func upgradeTLS(serverName: String) async throws {
        guard isConnected else {
            throw MockTransportError.notConnected
        }
        isTLSUpgraded = true
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard isConnected else {
            throw MockTransportError.notConnected
        }
        if let sendFailure {
            throw sendFailure
        }
        if let blockPredicate, !blockedReleased, blockPredicate(String(decoding: bytes, as: UTF8.self)) {
            await withCheckedContinuation { blockedSends.append($0) }
        }
        sentBytes.append(bytes)
        if let waiter = sentWaiters.removeValue(forKey: sentBytes.count) {
            waiter.resume()
        }
    }

    public func disconnect() {
        isConnected = false
        receivedContinuation.finish()
    }

    // MARK: - Test Helpers

    /// Makes the next `connect`/`connectWithTLS` throw `error`; the following attempt succeeds. Lets a test drive
    /// a same-instance reconnect: the failed attempt throws before `isConnected` is set, so the transport stays
    /// not-connected and its `receivedData` stream is left untouched for the next connect.
    public func failNextConnect(_ error: any Error) {
        nextConnectError = error
    }

    /// Suspends until `sentBytes.count >= count`. Returns immediately if already met.
    public func waitForSent(count: Int) async {
        if sentBytes.count >= count { return }
        await withCheckedContinuation { continuation in
            sentWaiters[count] = continuation
        }
    }

    /// Simulates receiving a UTF-8 string from the network.
    public func simulateReceive(_ string: String) {
        receivedContinuation.yield(Array(string.utf8))
    }

    /// Simulates the remote end closing the connection.
    public func simulateDisconnect() {
        receivedContinuation.finish()
    }

    public func simulateSendFailure(_ error: (any Error)?) {
        sendFailure = error
    }

    /// Clears the recorded sent bytes for isolation in tests.
    public func clearSentBytes() {
        sentBytes.removeAll()
        sentWaiters.removeAll()
    }

    /// Holds any send whose serialized stanza matches `predicate` until `releaseBlockedSends()` is called,
    /// so a test can keep a specific stanza (e.g. the entity-caps presence) off the wire while it observes
    /// gated behavior.
    public func blockSends(where predicate: @escaping @Sendable (String) -> Bool) {
        blockPredicate = predicate
        blockedReleased = false
    }

    public func releaseBlockedSends() {
        blockedReleased = true
        let pending = blockedSends
        blockedSends.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// Guard-failure errors for misuse of the mock (double connect, use before connect). Tests never assert on
/// the concrete type — they catch `any Error` — so this stays local rather than exposing DuckoXMPP's internal
/// `XMPPConnectionError`.
enum MockTransportError: Error {
    case alreadyConnected
    case notConnected
}
