import Darwin
import Logging

private let log = Logger(label: "im.ducko.xmpp.socks5listener")

/// SOCKS5 listening server for direct Jingle file transfer candidates (XEP-0260).
///
/// Listens on an ephemeral port for a single incoming SOCKS5 connection,
/// validates the handshake, and returns a `SOCKS5Connection` wrapping the
/// accepted socket.
actor SOCKS5Listener {
    // MARK: - Types

    /// Errors from the SOCKS5 listener.
    enum ListenerError: Error {
        case alreadyListening
        case socketCreationFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case acceptFailed(String)
        case handshakeFailed(String)
    }

    // MARK: - State

    private var listenFD: Int32 = -1

    // MARK: - Public API

    /// Starts listening on an ephemeral port.
    /// - Returns: The port number assigned by the OS.
    func start() throws -> UInt16 {
        guard listenFD == -1 else { throw ListenerError.alreadyListening }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.socketCreationFailed(errno) }

        // Allow address reuse
        var reuseAddr: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind to INADDR_ANY on port 0 (ephemeral)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw ListenerError.bindFailed(err)
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw ListenerError.listenFailed(err)
        }

        // Read assigned port
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &addrLen)
            }
        }

        listenFD = fd
        let port = UInt16(bigEndian: boundAddr.sin_port)
        log.info("SOCKS5 listener started on port \(port)")
        return port
    }

    /// Waits for one incoming connection, validates the SOCKS5 handshake,
    /// and returns a `SOCKS5Connection` wrapping the accepted socket.
    ///
    /// - Parameters:
    ///   - expectedDstAddr: The expected SOCKS5 DST.ADDR (SHA-1 hash string).
    ///   - timeout: Maximum seconds to wait for a connection.
    func accept(expectedDstAddr: String, timeout: Double = 60) async throws -> SOCKS5Connection {
        guard listenFD >= 0 else {
            throw ListenerError.acceptFailed("Not listening")
        }

        let fd = listenFD
        let dstAddr = expectedDstAddr

        return try await Task.detached {
            // Wait for incoming connection with poll()-based timeout
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pfd, 1, Int32(timeout) * 1000)
            guard pollResult > 0 else {
                if pollResult == 0 {
                    throw SOCKS5Listener.ListenerError.acceptFailed("Accept timed out")
                }
                throw SOCKS5Listener.ListenerError.acceptFailed("poll() failed: \(errno)")
            }

            // Accept incoming connection (returns immediately since poll confirmed readiness)
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let acceptedFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(fd, sa, &clientAddrLen)
                }
            }

            guard acceptedFD >= 0 else {
                throw SOCKS5Listener.ListenerError.acceptFailed("accept() failed: \(errno)")
            }

            do {
                try Self.performServerHandshake(fd: acceptedFD, expectedDstAddr: dstAddr)
            } catch {
                Darwin.close(acceptedFD)
                throw error
            }

            let connection = SOCKS5Connection()
            try await connection.adopt(fd: acceptedFD)
            return connection
        }.value
    }

    /// Closes the listening socket.
    func close() {
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    // MARK: - Private: Server Handshake

    /// Performs the SOCKS5 server-side handshake on an accepted socket.
    private static func performServerHandshake(
        fd: Int32,
        expectedDstAddr: String
    ) throws {
        // 1. Receive client greeting header (2 bytes: VER, NMETHODS)
        let greetingHeader = try SOCKS5Connection.recvAll(fd: fd, count: 2)
        guard greetingHeader[0] == 0x05, greetingHeader[1] > 0 else {
            throw ListenerError.handshakeFailed(
                "Invalid greeting header: \(greetingHeader)"
            )
        }

        // Read method list
        let methods = try SOCKS5Connection.recvAll(fd: fd, count: Int(greetingHeader[1]))
        guard methods.contains(0x00) else {
            // Send method rejection (0xFF = no acceptable methods)
            try SOCKS5Connection.sendAll(fd: fd, data: [0x05, 0xFF])
            throw ListenerError.handshakeFailed(
                "No acceptable auth method (no-auth not offered)"
            )
        }

        // 2. Send greeting response: NO AUTH accepted
        try SOCKS5Connection.sendAll(fd: fd, data: [0x05, 0x00])

        // 3. Receive CONNECT request header (4 bytes: VER, CMD, RSV, ATYP)
        let header = try SOCKS5Connection.recvAll(fd: fd, count: 4)
        guard header[0] == 0x05, header[1] == 0x01, header[3] == 0x03 else {
            throw ListenerError.handshakeFailed(
                "Invalid CONNECT request header: \(header)"
            )
        }

        // 4. Read domain address length + address + port
        let addrLenBytes = try SOCKS5Connection.recvAll(fd: fd, count: 1)
        let addrLen = Int(addrLenBytes[0])
        let addrBytes = try SOCKS5Connection.recvAll(fd: fd, count: addrLen)
        _ = try SOCKS5Connection.recvAll(fd: fd, count: 2) // port (ignored)

        // 5. Validate DST.ADDR (hex string — ASCII safe)
        let receivedAddr = String(decoding: addrBytes, as: UTF8.self)
        guard receivedAddr == expectedDstAddr else {
            throw ListenerError.handshakeFailed(
                "DST.ADDR mismatch: expected \(expectedDstAddr), got \(receivedAddr)"
            )
        }

        // 6. Send success response
        let response: [UInt8] = [
            0x05, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00
        ]
        try SOCKS5Connection.sendAll(fd: fd, data: response)

        log.info("SOCKS5 server handshake completed for \(expectedDstAddr)")
    }
}
