import Darwin

/// Test-only TCP server that accepts one loopback connection and then stalls —
/// it never writes a stream header or TLS response, so an XMPP client that
/// connects to it wedges *before* readiness. Used to drive the CLI's
/// presence-hold signal path into its pre-readiness teardown branch
/// deterministically, independent of host routing or process-bootstrap timing.
///
/// `start()` binds/listens synchronously and exposes the kernel-assigned `port`
/// without `await`; `waitForAcceptedConnection`/`shutdown` are actor-isolated.
actor LoopbackStallServer {
    nonisolated let port: UInt16
    private let listenFD: Int32
    private var acceptedFD: Int32?
    private var isShutDown = false

    private init(listenFD: Int32, port: UInt16) {
        self.listenFD = listenFD
        self.port = port
    }

    /// Binds a non-blocking listening socket to `127.0.0.1:0`. The kernel
    /// completes the TCP handshake for inbound connections from the `listen`
    /// backlog before `accept`, so a connecting client reaches its
    /// stream-negotiation wait regardless of when `waitForAcceptedConnection`
    /// dequeues the connection.
    static func start() throws -> LoopbackStallServer {
        let bound = try bindLoopbackTCPSocket(nonBlocking: true)
        guard listen(bound.fd, 1) == 0 else {
            let code = errno
            close(bound.fd)
            throw LoopbackTCPSocketError.socketSetupFailed(operation: "listen", errno: code)
        }
        return LoopbackStallServer(listenFD: bound.fd, port: bound.port)
    }

    /// Bounded readiness barrier: polls `accept` until the first connection is
    /// dequeued, then holds it open without writing. Throws
    /// `TestHarnessError.timeout` if no client connects before `timeout`.
    func waitForAcceptedConnection(timeout: Duration = TestTimeout.cliCommand) async throws {
        if acceptedFD != nil { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if isShutDown { throw TestHarnessError.timeout }
            let client = accept(listenFD, nil, nil)
            if client >= 0 {
                acceptedFD = client
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TestHarnessError.timeout
    }

    /// Closes the accepted and listening sockets. Idempotent.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        if let acceptedFD {
            close(acceptedFD)
            self.acceptedFD = nil
        }
        close(listenFD)
    }
}
