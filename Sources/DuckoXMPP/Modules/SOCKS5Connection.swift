import Darwin
import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "socks5")

/// SOCKS5 client connection for Jingle file transfer via XEP-0065 proxies.
///
/// Connects to a SOCKS5 proxy, performs the SOCKS5 handshake with the
/// XEP-0065 destination address (SHA-1 hash), and provides raw byte I/O.
actor SOCKS5Connection {
    // MARK: - Types

    /// Errors from the SOCKS5 connection.
    enum SOCKS5Error: Error {
        case connectionFailed(String)
        case handshakeFailed(String)
        case notConnected
        case alreadyConnected
        case sendFailed(String)
        case receiveFailed(String)
    }

    // MARK: - State

    private var fd: Int32 = -1

    // MARK: - Static Helpers

    /// Computes the SOCKS5 destination address per XEP-0065 §5.3.2:
    /// `SHA1(SID + initiatorJID + targetJID)` as a 40-char lowercase hex string.
    nonisolated static func destinationAddress(
        sid: String,
        initiatorJID: String,
        targetJID: String
    ) -> String {
        let input = sid + initiatorJID + targetJID
        return sha1Hex(Array(input.utf8))
    }

    /// SOCKS5 greeting: version 5, 1 method, NO AUTH (0x00).
    nonisolated static let greetingBytes: [UInt8] = [0x05, 0x01, 0x00]

    /// Builds a SOCKS5 CONNECT request for a domain address.
    ///
    /// Format: `[VER=5, CMD=1, RSV=0, ATYP=3, LEN, ADDR..., PORT_HI=0, PORT_LO=0]`
    nonisolated static func connectRequest(
        destinationAddress: String
    ) -> [UInt8] {
        let addrBytes = Array(destinationAddress.utf8)
        var request: [UInt8] = [0x05, 0x01, 0x00, 0x03]
        request.append(UInt8(addrBytes.count))
        request.append(contentsOf: addrBytes)
        request.append(contentsOf: [0x00, 0x00]) // port = 0
        return request
    }

    /// Validates the SOCKS5 greeting response (server method selection).
    nonisolated static func validateGreetingResponse(
        _ response: [UInt8]
    ) throws {
        guard response.count == 2 else {
            throw SOCKS5Error.handshakeFailed(
                "Greeting response length \(response.count), expected 2"
            )
        }
        guard response[0] == 0x05 else {
            throw SOCKS5Error.handshakeFailed(
                "Greeting version \(response[0]), expected 5"
            )
        }
        guard response[1] == 0x00 else {
            throw SOCKS5Error.handshakeFailed(
                "Server rejected auth methods (method=\(response[1]))"
            )
        }
    }

    /// Validates the SOCKS5 CONNECT response.
    nonisolated static func validateConnectResponse(
        _ response: [UInt8]
    ) throws {
        guard response.count >= 2 else {
            throw SOCKS5Error.handshakeFailed(
                "Connect response too short (\(response.count) bytes)"
            )
        }
        guard response[0] == 0x05 else {
            throw SOCKS5Error.handshakeFailed(
                "Connect response version \(response[0]), expected 5"
            )
        }
        guard response[1] == 0x00 else {
            throw SOCKS5Error.handshakeFailed(
                "SOCKS5 connect failed: reply code \(response[1])"
            )
        }
    }

    // MARK: - Public API

    /// Adopts an already-connected socket file descriptor for data transfer.
    /// Used by SOCKS5Listener after accepting and validating an incoming connection.
    func adopt(fd newFD: Int32) throws {
        guard fd == -1 else { throw SOCKS5Error.alreadyConnected }
        fd = newFD
    }

    /// Connects to a SOCKS5 proxy and performs the handshake.
    func connect(
        host: String,
        port: UInt16,
        destinationAddress: String
    ) async throws {
        guard fd == -1 else { throw SOCKS5Error.alreadyConnected }

        fd = try await Task.detached {
            let socketFD = try Self.resolveAndConnect(
                host: host,
                port: port
            )
            do {
                try Self.performHandshake(
                    fd: socketFD,
                    destinationAddress: destinationAddress
                )
            } catch {
                Darwin.close(socketFD)
                throw error
            }
            return socketFD
        }.value

        log.info("SOCKS5 connected to \(host):\(port)")
    }

    /// Sends data over the established SOCKS5 connection.
    func send(_ data: [UInt8]) async throws {
        guard fd >= 0 else { throw SOCKS5Error.notConnected }

        let fdCopy = fd
        try await Task.detached {
            try Self.sendAll(fd: fdCopy, data: data)
        }.value
    }

    /// Receives exactly `count` bytes from the connection.
    func receive(_ count: Int) async throws -> [UInt8] {
        guard fd >= 0 else { throw SOCKS5Error.notConnected }

        let fdCopy = fd
        return try await Task.detached {
            try Self.recvAll(fd: fdCopy, count: count)
        }.value
    }

    /// Closes the SOCKS5 connection.
    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: - Private: Socket I/O

    private static func resolveAndConnect(
        host: String,
        port: UInt16
    ) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        let err = getaddrinfo(host, portStr, &hints, &result)
        guard err == 0, let addrList = result else {
            throw SOCKS5Error.connectionFailed("getaddrinfo failed: \(err)")
        }
        defer { freeaddrinfo(addrList) }

        var lastError: Int32 = 0
        var addr: UnsafeMutablePointer<addrinfo>? = addrList
        while let ai = addr {
            let socketFD = socket(
                ai.pointee.ai_family,
                ai.pointee.ai_socktype,
                ai.pointee.ai_protocol
            )
            guard socketFD >= 0 else {
                addr = ai.pointee.ai_next
                continue
            }

            if Darwin.connect(
                socketFD,
                ai.pointee.ai_addr,
                ai.pointee.ai_addrlen
            ) == 0 {
                return socketFD
            }
            lastError = errno
            Darwin.close(socketFD)
            addr = ai.pointee.ai_next
        }
        throw SOCKS5Error.connectionFailed("connect() failed: \(lastError)")
    }

    private static func performHandshake(
        fd: Int32,
        destinationAddress: String
    ) throws {
        // Send greeting
        try sendAll(fd: fd, data: greetingBytes)

        // Read greeting response (2 bytes)
        let greetingResponse = try recvAll(fd: fd, count: 2)
        try validateGreetingResponse(greetingResponse)

        // Send CONNECT request
        let request = connectRequest(destinationAddress: destinationAddress)
        try sendAll(fd: fd, data: request)

        // Read CONNECT response header (5 bytes: VER, REP, RSV, ATYP, first addr byte)
        let header = try recvAll(fd: fd, count: 5)
        try validateConnectResponse(header)

        // Read remaining bytes based on address type
        let remaining = connectResponseRemainingBytes(header)
        if remaining > 0 {
            _ = try recvAll(fd: fd, count: remaining)
        }
    }

    /// Determines how many more bytes to read after the 5-byte CONNECT response header.
    private static func connectResponseRemainingBytes(
        _ header: [UInt8]
    ) -> Int {
        guard header.count >= 5 else { return 0 }
        let atyp = header[3]
        switch atyp {
        case 0x01: // IPv4: 3 more addr bytes + 2 port bytes
            return 5
        case 0x03: // Domain: header[4] is length, then domain + 2 port bytes
            return Int(header[4]) + 2
        case 0x04: // IPv6: 15 more addr bytes + 2 port bytes
            return 17
        default:
            return 0
        }
    }

    static func sendAll(fd: Int32, data: [UInt8]) throws {
        try data.withUnsafeBufferPointer { buf in
            var totalSent = 0
            while totalSent < data.count {
                let sent = Darwin.send(
                    fd,
                    buf.baseAddress! + totalSent,
                    data.count - totalSent,
                    0
                )
                if sent < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                        continue
                    }
                    throw SOCKS5Error.sendFailed("send() failed: \(errno)")
                }
                guard sent > 0 else {
                    throw SOCKS5Error.sendFailed("send() returned 0")
                }
                totalSent += sent
            }
        }
    }

    static func recvAll(fd: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var totalRead = 0
        try buffer.withUnsafeMutableBytes { buf in
            while totalRead < count {
                let result = recv(
                    fd,
                    buf.baseAddress! + totalRead,
                    count - totalRead,
                    0
                )
                if result < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                        continue
                    }
                    throw SOCKS5Error.receiveFailed("recv() failed: \(errno)")
                }
                guard result > 0 else {
                    throw SOCKS5Error.receiveFailed(
                        "Connection closed after \(totalRead)/\(count) bytes"
                    )
                }
                totalRead += result
            }
        }
        return buffer
    }
}
