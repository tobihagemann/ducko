import Darwin
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func bindLoopbackSocket() throws -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(bindResult == 0)

    var boundAddr = sockaddr_in()
    var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(fd, sa, &addrLen)
        }
    }
    try #require(nameResult == 0)
    return (fd, UInt16(bigEndian: boundAddr.sin_port))
}

// MARK: - Tests

enum POSIXTransportTests {
    struct ErrorText {
        @Test
        func `posixErrorText renders errno as readable text`() {
            #expect(posixErrorText(ECONNREFUSED) == "Connection refused")
        }

        @Test
        func `addressInfoErrorText renders resolver errors as readable text`() {
            #expect(addressInfoErrorText(EAI_NONAME) == "nodename nor servname provided, or not known")
        }

        @Test
        func `addressInfoErrorText reports errno for system resolver errors`() {
            let text = { () -> String in
                errno = ECONNREFUSED
                return addressInfoErrorText(EAI_SYSTEM)
            }()
            #expect(text == "Connection refused")
        }
    }

    struct ConnectFailure {
        @Test
        func `Connecting to a closed port reports a readable reason`() async throws {
            let (fd, port) = try bindLoopbackSocket()
            close(fd)

            let transport = POSIXTransport()
            let error = await #expect(throws: XMPPClientError.self) {
                try await transport.connect(host: "127.0.0.1", port: port)
            }

            guard case let .connectionFailed(reason) = error else {
                Issue.record("Expected connectionFailed, got \(String(describing: error))")
                return
            }
            #expect(reason.contains("Connection refused"))
        }
    }

    struct TLSFailure {
        @Test
        func `A non-TLS reply to the handshake reports a readable reason`() async throws {
            let (listenFD, port) = try bindLoopbackSocket()
            try #require(listen(listenFD, 1) == 0)

            // Reads the ClientHello before replying, so the transport's plain receive loop has already stopped
            // and can't consume the junk. The server then holds the socket open until the client disconnects,
            // so the client never writes into a closed peer.
            let server = Task.detached {
                let clientFD = accept(listenFD, nil, nil)
                guard clientFD >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                _ = recv(clientFD, &buffer, buffer.count, 0)
                let junk = Array("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)
                _ = Darwin.send(clientFD, junk, junk.count, 0)
                while recv(clientFD, &buffer, buffer.count, 0) > 0 {}
                close(clientFD)
            }

            let transport = POSIXTransport()
            try await transport.connect(host: "127.0.0.1", port: port)
            let error = await #expect(throws: XMPPClientError.self) {
                try await transport.upgradeTLS(serverName: "localhost")
            }
            await transport.disconnect()
            await server.value
            close(listenFD)

            guard case let .tlsNegotiationFailed(reason) = error else {
                Issue.record("Expected tlsNegotiationFailed, got \(String(describing: error))")
                return
            }
            #expect(reason.hasPrefix("TLS handshake failed: "))
            #expect(!reason.contains { $0.isNumber })
        }
    }

    struct SendFailure {
        @Test
        func `Sending on a reset connection reports a readable reason`() async throws {
            let (listenFD, port) = try bindLoopbackSocket()
            try #require(listen(listenFD, 1) == 0)

            // A zero linger timeout makes close send RST instead of FIN.
            let server = Task.detached {
                let clientFD = accept(listenFD, nil, nil)
                guard clientFD >= 0 else { return }
                var lingerOption = linger(l_onoff: 1, l_linger: 0)
                _ = setsockopt(clientFD, SOL_SOCKET, SO_LINGER, &lingerOption, socklen_t(MemoryLayout<linger>.size))
                close(clientFD)
            }

            let transport = POSIXTransport()
            try await transport.connect(host: "127.0.0.1", port: port)
            await server.value
            close(listenFD)
            // The receive loop ends once it observes the reset, so the send below deterministically hits it.
            for await _ in transport.receivedData {}

            let error = await #expect(throws: XMPPClientError.self) {
                try await transport.send(Array("<presence/>".utf8))
            }
            await transport.disconnect()

            guard case let .sendFailed(reason) = error else {
                Issue.record("Expected sendFailed, got \(String(describing: error))")
                return
            }
            #expect(reason == "Broken pipe")
        }
    }
}
