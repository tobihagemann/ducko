import Darwin
import DuckoTestSupport
import Foundation
@preconcurrency import Security
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
    return try (fd, boundPort(of: fd))
}

private func listeningLoopbackSocket() throws -> (fd: Int32, port: UInt16) {
    let (fd, port) = try bindLoopbackSocket()
    try #require(listen(fd, 1) == 0)
    return (fd, port)
}

private func bindSocket(at address: addrinfo) throws -> (fd: Int32, port: UInt16) {
    let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
    try #require(fd >= 0)
    try #require(bind(fd, address.ai_addr, address.ai_addrlen) == 0)
    return try (fd, boundPort(of: fd))
}

private func socketAddress(
    of fd: Int32,
    _ query: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32
) throws -> sockaddr_storage {
    var storage = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let result = withUnsafeMutablePointer(to: &storage) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            query(fd, sa, &length)
        }
    }
    try #require(result == 0)
    return storage
}

/// Accepts one connection and reads the client's first bytes without ever replying, returning the accepted socket.
private func acceptWithoutReplying(on listenFD: Int32) -> Task<Int32, Never> {
    Task.detached {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return clientFD }
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = recv(clientFD, &buffer, buffer.count, 0)
        return clientFD
    }
}

/// A throwaway self-signed identity for `CN=localhost`, as a PKCS#12 archive protected by the password "ducko".
private let selfSignedIdentityArchive = """
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
"""

/// Imports the self-signed test identity into memory, without touching a keychain.
private func selfSignedIdentity() -> SecIdentity? {
    guard let archive = Data(base64Encoded: selfSignedIdentityArchive, options: .ignoreUnknownCharacters) else {
        return nil
    }
    let options = [kSecImportExportPassphrase: "ducko", kSecImportToMemoryOnly: true] as CFDictionary
    var items: CFArray?
    guard SecPKCS12Import(archive as CFData, options, &items) == errSecSuccess,
          let entry = (items as? [[String: Any]])?.first,
          let identity = entry[kSecImportItemIdentity as String] else {
        return nil
    }
    // swiftlint:disable:next force_cast
    return (identity as! SecIdentity)
}

/// Accepts one connection and answers its TLS handshake with the self-signed identity, returning the accepted socket.
private func acceptWithSelfSignedTLS(on listenFD: Int32) -> Task<Int32, Never> {
    Task.detached {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0,
              let identity = selfSignedIdentity(),
              let ctx = SSLCreateContext(nil, .serverSide, .streamType) else {
            return clientFD
        }
        disableSIGPIPE(clientFD)
        let connection = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        defer { connection.deallocate() }
        connection.pointee = clientFD
        _ = SSLSetIOFuncs(ctx, blockingSSLRead, blockingSSLWrite)
        _ = SSLSetConnection(ctx, UnsafeMutableRawPointer(connection))
        _ = SSLSetCertificate(ctx, [identity] as CFArray)
        // The socket blocks, so the handshake runs until the client completes or abandons it.
        _ = SSLHandshake(ctx)
        return clientFD
    }
}

private func blockingSSLRead(
    connection: SSLConnectionRef,
    data: UnsafeMutableRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fd = connection.assumingMemoryBound(to: Int32.self).pointee
    let requested = dataLength.pointee
    let received = recv(fd, data, requested, MSG_WAITALL)
    dataLength.pointee = max(received, 0)
    return received == requested ? errSecSuccess : errSSLClosedGraceful
}

private func blockingSSLWrite(
    connection: SSLConnectionRef,
    data: UnsafeRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fd = connection.assumingMemoryBound(to: Int32.self).pointee
    let requested = dataLength.pointee
    let sent = Darwin.send(fd, data, requested, 0)
    dataLength.pointee = max(sent, 0)
    return sent == requested ? errSecSuccess : errSSLClosedAbort
}

/// Connects `transport` to a loopback peer that doesn't read, with a receive window small enough that a large send
/// waits for the socket. Returns the accepted and listening sockets for the caller to close.
private func connectToNonReadingPeer(_ transport: POSIXTransport) async throws -> (serverFD: Int32, listenFD: Int32) {
    let (listenFD, port) = try bindLoopbackSocket()
    var receiveBufferSize: Int32 = 4096
    setsockopt(listenFD, SOL_SOCKET, SO_RCVBUF, &receiveBufferSize, socklen_t(MemoryLayout<Int32>.size))
    try #require(listen(listenFD, 1) == 0)
    let accepted = Task.detached { accept(listenFD, nil, nil) }
    try await transport.connect(host: "127.0.0.1", port: port)
    let serverFD = await accepted.value
    try #require(serverFD >= 0)
    return (serverFD, listenFD)
}

private func boundPort(of fd: Int32) throws -> UInt16 {
    let storage = try socketAddress(of: fd, getsockname)
    // sin_port and sin6_port share the same offset, so reading through sockaddr_in covers both families.
    let port = withUnsafeBytes(of: storage) { $0.load(as: sockaddr_in.self).sin_port }
    return UInt16(bigEndian: port)
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

    struct AddressFallback {
        @Test
        func `connectTCPSocket falls back to the next resolved address`() throws {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            try #require(getaddrinfo("localhost", "0", &hints, &result) == 0)
            let addrList = try #require(result)
            defer { freeaddrinfo(addrList) }

            let addresses = Array(sequence(first: addrList.pointee) { $0.ai_next?.pointee })
            let first = try #require(addresses.first)
            let last = try #require(addresses.last)
            // Two families guarantee an earlier address to fall back from, and let the peer family identify the last one.
            try #require(first.ai_family != last.ai_family)

            // Only the last address listens, so every earlier connect is refused.
            let (listenFD, port) = try bindSocket(at: last)
            defer { close(listenFD) }
            try #require(listen(listenFD, 1) == 0)

            let clientFD = try connectTCPSocket(host: "localhost", port: port)
            defer { close(clientFD) }

            let peerAddr = try socketAddress(of: clientFD, getpeername)
            #expect(Int32(peerAddr.ss_family) == last.ai_family)
        }
    }

    struct TLSFailure {
        @Test
        func `A non-TLS reply to the handshake reports a readable reason`() async throws {
            let (listenFD, port) = try listeningLoopbackSocket()

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
            await transport.stopReceiving()
            let error = await #expect(throws: XMPPClientError.self) {
                _ = try await transport.upgradeTLS(serverName: "localhost")
            }
            await transport.disconnect()
            await server.value
            close(listenFD)

            guard case let .tlsNegotiationFailed(reason) = error else {
                Issue.record("Expected tlsNegotiationFailed, got \(String(describing: error))")
                return
            }
            #expect(!reason.isEmpty)
            #expect(!reason.hasPrefix("TLS handshake failed"))
            #expect(!reason.contains { $0.isNumber })
        }

        @Test
        func `Upgrading while still reading is refused`() async throws {
            let (listenFD, port) = try listeningLoopbackSocket()
            let server = Task.detached { accept(listenFD, nil, nil) }

            // A short handshake timeout means a handshake that did start would fail with a different reason.
            let transport = POSIXTransport(handshakeTimeout: .milliseconds(100))
            try await transport.connect(host: "127.0.0.1", port: port)
            let serverFD = await server.value
            let outcome = try await boundedOutcome {
                _ = try await transport.upgradeTLS(serverName: "localhost")
            }
            await transport.disconnect()
            close(serverFD)
            close(listenFD)

            let result = try #require(outcome)
            let error = #expect(throws: XMPPClientError.self) { try result.get() }
            guard case let .tlsNegotiationFailed(reason) = error else {
                Issue.record("Expected tlsNegotiationFailed, got \(String(describing: error))")
                return
            }
            #expect(reason == "Reading had not stopped before the secure connection started")
        }

        @Test
        func `Disconnecting during a TLS handshake ends the handshake`() async throws {
            let (listenFD, port) = try listeningLoopbackSocket()

            let server = acceptWithoutReplying(on: listenFD)

            let transport = POSIXTransport()
            let connectTask = Task {
                try await transport.connectWithTLS(host: "127.0.0.1", port: port, serverName: "localhost")
            }
            let serverFD = await server.value
            let disconnected = try await boundedOutcome { await transport.disconnect() }
            let outcome = try await boundedOutcome { try await connectTask.value }
            close(serverFD)
            close(listenFD)

            #expect(disconnected != nil)
            let result = try #require(outcome)
            #expect(throws: XMPPClientError.self) { try result.get() }
        }

        @Test
        func `A server that never answers the TLS handshake times out`() async throws {
            let (listenFD, port) = try listeningLoopbackSocket()
            let server = acceptWithoutReplying(on: listenFD)

            let transport = POSIXTransport(handshakeTimeout: .milliseconds(100))
            let outcome = try await boundedOutcome {
                try await transport.connectWithTLS(host: "127.0.0.1", port: port, serverName: "localhost")
            }
            await close(server.value)
            close(listenFD)

            let result = try #require(outcome)
            let error = #expect(throws: XMPPClientError.self) { try result.get() }
            guard case let .tlsNegotiationFailed(reason) = error else {
                Issue.record("Expected tlsNegotiationFailed, got \(String(describing: error))")
                return
            }
            #expect(reason == "The server did not complete the TLS handshake in time")
        }

        @Test
        func `A server certificate that fails trust evaluation is rejected`() async throws {
            try #require(selfSignedIdentity() != nil)
            let (listenFD, port) = try listeningLoopbackSocket()
            let server = acceptWithSelfSignedTLS(on: listenFD)

            let transport = POSIXTransport()
            let outcome = try await boundedOutcome {
                try await transport.connectWithTLS(host: "127.0.0.1", port: port, serverName: "localhost")
            }
            await close(server.value)
            close(listenFD)

            let result = try #require(outcome)
            let error = #expect(throws: XMPPClientError.self) { try result.get() }
            guard case let .tlsNegotiationFailed(reason) = error else {
                Issue.record("Expected tlsNegotiationFailed, got \(String(describing: error))")
                return
            }
            #expect(!reason.isEmpty)
            #expect(reason != "The server did not complete the TLS handshake in time")
            #expect(reason != "The server's certificate was not verified")
        }

        @Test
        func `Cancelling a TLS connect ends the handshake`() async throws {
            let (listenFD, port) = try listeningLoopbackSocket()
            let server = acceptWithoutReplying(on: listenFD)

            let transport = POSIXTransport()
            let connectTask = Task {
                try await transport.connectWithTLS(host: "127.0.0.1", port: port, serverName: "localhost")
            }
            let serverFD = await server.value
            connectTask.cancel()
            let outcome = try await boundedOutcome { try await connectTask.value }
            close(serverFD)
            close(listenFD)

            let result = try #require(outcome)
            #expect(throws: CancellationError.self) { try result.get() }
        }
    }

    struct ReceivePhases {
        @Test
        func `Stopping receipt finishes the receive stream`() async throws {
            let (listenFD, port) = try listeningLoopbackSocket()
            let payload = Array(testProceed.utf8)
            // Sends the payload and holds the socket open, so only stopping receipt can end the stream.
            let server = Task.detached {
                let clientFD = accept(listenFD, nil, nil)
                if clientFD >= 0 {
                    _ = Darwin.send(clientFD, payload, payload.count, 0)
                }
                return clientFD
            }

            let transport = POSIXTransport()
            try await transport.connect(host: "127.0.0.1", port: port)
            let serverFD = await server.value
            let receivedData = transport.receivedData
            let outcome = try await boundedOutcome {
                var iterator = receivedData.makeAsyncIterator()
                var received: [UInt8] = []
                while received.count < payload.count, let chunk = await iterator.next() {
                    received += chunk
                }
                await transport.stopReceiving()
                guard received == payload, await iterator.next() == nil else {
                    throw XMPPClientError.unexpectedStreamState("The receive stream did not end after the payload")
                }
            }
            await transport.disconnect()
            close(serverFD)
            close(listenFD)

            let result = try #require(outcome)
            #expect(throws: Never.self) { try result.get() }
        }
    }

    struct SendFailure {
        @Test
        func `Sending on a reset connection reports a readable reason`() async throws {
            let (listenFD, port) = try listeningLoopbackSocket()

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

        @Test
        func `A send after a failed send still goes out`() async throws {
            let (listenFD, port) = try listeningLoopbackSocket()
            let accepted = Task.detached { accept(listenFD, nil, nil) }

            let transport = POSIXTransport()
            await #expect(throws: XMPPClientError.self) {
                try await transport.send(Array("<early/>".utf8))
            }
            try await transport.connect(host: "127.0.0.1", port: port)
            let serverFD = await accepted.value
            try #require(serverFD >= 0)

            let stanza = Array("<presence/>".utf8)
            try await transport.send(stanza)
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = recv(serverFD, &buffer, buffer.count, 0)
            await transport.disconnect()
            close(serverFD)
            close(listenFD)

            #expect(Array(buffer.prefix(max(count, 0))) == stanza)
        }
    }

    struct StalledSend {
        @Test
        func `Disconnecting during a stalled send ends the send`() async throws {
            let transport = POSIXTransport()
            let (serverFD, listenFD) = try await connectToNonReadingPeer(transport)

            let send = Task { try await transport.send([UInt8](repeating: 0x61, count: 1 << 20)) }
            let early = try await boundedOutcome(timeout: .milliseconds(100)) { try await send.value }
            try #require(early == nil)
            await transport.disconnect()
            let outcome = try await boundedOutcome { try await send.value }
            close(serverFD)
            close(listenFD)

            let result = try #require(outcome)
            let error = #expect(throws: XMPPClientError.self) { try result.get() }
            guard case .notConnected = error else {
                Issue.record("Expected notConnected, got \(String(describing: error))")
                return
            }
        }

        @Test
        func `A send the peer never drains times out`() async throws {
            let transport = POSIXTransport(writeTimeout: .milliseconds(100))
            let (serverFD, listenFD) = try await connectToNonReadingPeer(transport)

            let outcome = try await boundedOutcome {
                try await transport.send([UInt8](repeating: 0x61, count: 1 << 20))
            }
            await transport.disconnect()
            close(serverFD)
            close(listenFD)

            let result = try #require(outcome)
            let error = #expect(throws: XMPPClientError.self) { try result.get() }
            guard case let .sendFailed(reason) = error else {
                Issue.record("Expected sendFailed, got \(String(describing: error))")
                return
            }
            #expect(reason == "Timed out waiting to send data")
        }
    }

    struct SendOrdering {
        @Test
        func `Concurrent sends that wait for the socket stay in order`() async throws {
            let transport = POSIXTransport()
            let (serverFD, listenFD) = try await connectToNonReadingPeer(transport)

            let payloadSize = 1 << 20
            let firstSend = Task { try await transport.send([UInt8](repeating: 0x61, count: payloadSize)) }
            // The first send is waiting for the socket before the second one starts, so the second's bytes could
            // interleave with the first's or go out ahead of them if writes weren't chained.
            let firstEarly = try await boundedOutcome(timeout: .milliseconds(100)) { try await firstSend.value }
            try #require(firstEarly == nil)
            let secondSend = Task { try await transport.send([UInt8](repeating: 0x62, count: payloadSize)) }
            let secondEarly = try await boundedOutcome(timeout: .milliseconds(50)) { try await secondSend.value }
            try #require(secondEarly == nil)

            let reader = Task.detached { () -> [UInt8] in
                var received: [UInt8] = []
                var buffer = [UInt8](repeating: 0, count: 65536)
                while received.count < 2 * payloadSize {
                    let count = recv(serverFD, &buffer, buffer.count, 0)
                    guard count > 0 else { break }
                    received.append(contentsOf: buffer[..<count])
                }
                return received
            }
            try await firstSend.value
            try await secondSend.value
            let received = await reader.value
            await transport.disconnect()
            close(serverFD)
            close(listenFD)

            try #require(received.count == 2 * payloadSize)
            let runs = zip(received, received.dropFirst()).count { $0 != $1 } + 1
            #expect(runs == 2)
            #expect(received.first == 0x61)
        }
    }
}
