import DuckoXMPP

/// Shared in-memory ``XMPPTransport`` mock for both DuckoCoreTests and DuckoXMPPTests. Records sent bytes,
/// replays scripted server stanzas via ``simulateReceive(_:)``, and supports connect-error injection, send
/// failures, and send-blocking (to hold a specific stanza off the wire while a test observes gated behavior).
///
/// Models receive phases like the real transport: `stopReceiving()` finishes the current stream and `upgradeTLS`
/// returns a fresh one, which ``simulateReceive(_:)`` then feeds.
public actor MockTransport: XMPPTransport {
    public nonisolated let receivedData: AsyncStream<[UInt8]>
    /// Continuation of the current receive phase's stream: `receivedData`'s until `upgradeTLS` replaces it.
    private var receivedContinuation: AsyncStream<[UInt8]>.Continuation
    private var isReceivingStopped = false
    public private(set) var sentBytes: [[UInt8]] = []
    public private(set) var isConnected = false
    public private(set) var isTLSUpgraded = false
    public private(set) var connectedHost: String?
    public private(set) var connectedPort: UInt16?
    /// The most recent TLS server name (SNI) passed to `connectWithTLS`/`upgradeTLS`.
    public private(set) var tlsServerName: String?

    private var disconnectGate: (entered: AsyncSemaphore, release: AsyncSemaphore)?
    private let connectError: (any Error)?
    private var nextConnectError: (any Error)?
    private var matchingSendFailure: (fragment: String, error: any Error)?
    private var sendFailure: (any Error)?
    private var sentWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private struct PredicateSentWaiter {
        let predicate: @Sendable (String) -> Bool
        let continuation: CheckedContinuation<String?, Never>
    }

    private var nextPredicateSentWaiterID = 0
    private var predicateSentWaiters: [Int: PredicateSentWaiter] = [:]
    private var blockPredicate: (@Sendable (String) -> Bool)?
    private var blockedSends: [CheckedContinuation<Void, Never>] = []
    private var blockedReleased = false
    private var autoReplies: [@Sendable (String) -> String?] = []

    /// A connected server answers the client's `</stream:stream>` with its own (RFC 6120 §4.4), so the mock does
    /// too unless `repliesToStreamClose` is `false`.
    public init(connectError: (any Error)? = nil, repliesToStreamClose: Bool = true) {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        self.receivedData = stream
        self.receivedContinuation = continuation
        self.connectError = connectError
        if repliesToStreamClose {
            autoReplies.append { $0.hasPrefix("</stream:stream>") ? "</stream:stream>" : nil }
        }
    }

    public func connect(host: String, port: UInt16) async throws {
        if let error = takeConnectError() {
            throw error
        }
        guard !isConnected else {
            throw XMPPClientError.alreadyConnected
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
            throw XMPPClientError.alreadyConnected
        }
        isConnected = true
        isTLSUpgraded = true
        connectedHost = host
        connectedPort = port
        tlsServerName = serverName
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

    /// Bytes simulated before the next `upgradeTLS` are dropped, standing in for bytes left unread in the socket.
    public func stopReceiving() {
        receivedContinuation.finish()
        isReceivingStopped = true
    }

    public func upgradeTLS(serverName: String) throws -> AsyncStream<[UInt8]> {
        guard isConnected else {
            throw XMPPClientError.notConnected
        }
        guard isReceivingStopped else {
            throw XMPPClientError.tlsNegotiationFailed("Reading had not stopped before the secure connection started")
        }
        isTLSUpgraded = true
        tlsServerName = serverName
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        receivedContinuation = continuation
        isReceivingStopped = false
        return stream
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard isConnected else {
            throw XMPPClientError.notConnected
        }
        let stanza = String(decoding: bytes, as: UTF8.self)
        if let failure = matchingSendFailure, stanza.contains(failure.fragment) {
            matchingSendFailure = nil
            throw failure.error
        }
        if let sendFailure {
            throw sendFailure
        }
        if let blockPredicate, !blockedReleased, blockPredicate(stanza) {
            await withCheckedContinuation { blockedSends.append($0) }
        }
        sentBytes.append(bytes)
        if let waiter = sentWaiters.removeValue(forKey: sentBytes.count) {
            waiter.resume()
        }
        for id in predicateSentWaiters.compactMap({ $0.value.predicate(stanza) ? $0.key : nil }) {
            predicateSentWaiters.removeValue(forKey: id)?.continuation.resume(returning: stanza)
        }
        for reply in autoReplies {
            if let reply = reply(stanza) {
                simulateReceive(reply)
            }
        }
    }

    public func disconnect() async {
        if let gate = disconnectGate {
            disconnectGate = nil
            await gate.entered.signal()
            await gate.release.wait()
        }
        isConnected = false
        receivedContinuation.finish()
    }

    public func installDisconnectGate(entered: AsyncSemaphore, release: AsyncSemaphore) {
        disconnectGate = (entered, release)
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

    /// Suspends until a sent stanza satisfies `predicate`, returning the matching stanza, or `nil` if the
    /// awaiting task is cancelled (e.g. a timeout race). Already-sent bytes are scanned before registering, so
    /// a send that lands before the waiter registers is not missed — actor isolation makes the wait
    /// deterministic with no polling.
    public func waitForSent(matching predicate: @escaping @Sendable (String) -> Bool) async -> String? {
        let id = nextPredicateSentWaiterID
        nextPredicateSentWaiterID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                if let match = sentBytes.lazy.map({ String(decoding: $0, as: UTF8.self) }).first(where: predicate) {
                    continuation.resume(returning: match)
                    return
                }
                predicateSentWaiters[id] = PredicateSentWaiter(predicate: predicate, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelPredicateSentWaiter(id) }
        }
    }

    private func cancelPredicateSentWaiter(_ id: Int) {
        predicateSentWaiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
    }

    /// Simulates receiving a UTF-8 string from the network.
    public func simulateReceive(_ string: String) {
        receivedContinuation.yield(Array(string.utf8))
    }

    /// Simulates the remote end closing the connection.
    public func simulateDisconnect() {
        receivedContinuation.finish()
    }

    public func failNextSend(matching fragment: String, error: any Error) {
        matchingSendFailure = (fragment, error)
    }

    public func simulateSendFailure(_ error: (any Error)?) {
        sendFailure = error
    }

    /// Clears the recorded sent bytes for isolation in tests.
    public func clearSentBytes() {
        sentBytes.removeAll()
        sentWaiters.removeAll()
        for waiter in predicateSentWaiters.values {
            waiter.continuation.resume(returning: nil)
        }
        predicateSentWaiters.removeAll()
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

    /// Feeds `reply`'s result for a sent stanza back as received, from inside `send`, so a scripted server reply
    /// cannot land before the stanza it answers.
    public func autoReply(_ reply: @escaping @Sendable (String) -> String?) {
        autoReplies.append(reply)
    }
}
