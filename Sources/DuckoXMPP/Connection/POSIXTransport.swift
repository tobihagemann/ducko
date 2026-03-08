import Darwin
@preconcurrency import Security

/// POSIX socket transport with in-place STARTTLS support via Security.framework.
///
/// Unlike ``NWConnectionTransport``, this transport upgrades TLS on the existing
/// TCP socket — required for servers that only support STARTTLS (not direct TLS).
///
/// Uses the deprecated Secure Transport API (`SSLCreateContext`) because Network.framework
/// does not support in-place TLS upgrade. If Apple removes Secure Transport in a future
/// macOS release, this will need to be replaced with swift-nio-ssl or similar.
actor POSIXTransport: XMPPTransport {
    private var fd: Int32 = -1
    private var sslContext: SSLContext?
    private var receiveTask: Task<Void, Never>?

    nonisolated let receivedData: AsyncStream<[UInt8]>
    private nonisolated let receivedContinuation: AsyncStream<[UInt8]>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        self.receivedData = stream
        self.receivedContinuation = continuation
    }

    func connect(host: String, port: UInt16) async throws {
        guard fd == -1 else { throw XMPPConnectionError.alreadyConnected }

        fd = try await resolveAndConnect(host: host, port: port)
        setNonBlocking(true)
        startReceiving()
    }

    func upgradeTLS(serverName: String) async throws {
        guard fd >= 0 else { throw XMPPConnectionError.notConnected }

        receiveTask?.cancel()
        await receiveTask?.value
        receiveTask = nil

        // SSLHandshake requires a blocking socket
        setNonBlocking(false)

        let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        fdPtr.pointee = fd

        do {
            let ctx = try configureSSL(fdPtr: fdPtr, serverName: serverName)

            // Run blocking TLS work on a non-cooperative thread
            try await Task.detached {
                var status = SSLHandshake(ctx)
                while status == errSSLWouldBlock {
                    status = SSLHandshake(ctx)
                }
                guard status == errSecSuccess else {
                    throw XMPPConnectionError.tlsUpgradeFailed("TLS handshake failed: OSStatus \(status)")
                }

                try validatePeerTrust(ctx: ctx)
            }.value

            // Publish sslContext only after handshake succeeds to prevent
            // the receive task from calling SSLRead during the handshake
            sslContext = ctx
        } catch {
            sslContext = nil
            fdPtr.deallocate()
            throw error
        }

        setNonBlocking(true)
        startReceiving()
    }

    func send(_ bytes: [UInt8]) async throws {
        guard fd >= 0 else { throw XMPPConnectionError.notConnected }

        if let ctx = sslContext {
            try sendSSL(ctx: ctx, bytes: bytes)
        } else {
            try sendPlain(bytes: bytes)
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        tearDownSSL()
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        receivedContinuation.finish()
    }

    // MARK: - Private

    private func tearDownSSL() {
        guard let ctx = sslContext else { return }
        SSLClose(ctx)
        var connRef: SSLConnectionRef?
        SSLGetConnection(ctx, &connRef)
        connRef?.assumingMemoryBound(to: Int32.self).deallocate()
        sslContext = nil
    }

    private func setNonBlocking(_ enabled: Bool) {
        let flags = fcntl(fd, F_GETFL)
        if enabled {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        } else {
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
    }

    private func configureSSL(
        fdPtr: UnsafeMutablePointer<Int32>,
        serverName: String
    ) throws -> SSLContext {
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw XMPPConnectionError.tlsUpgradeFailed("Failed to create SSL context")
        }

        var status = SSLSetIOFuncs(ctx, posixSSLRead, posixSSLWrite)
        guard status == errSecSuccess else {
            throw XMPPConnectionError.tlsUpgradeFailed("SSLSetIOFuncs failed: \(status)")
        }

        status = SSLSetConnection(ctx, UnsafeMutableRawPointer(fdPtr))
        guard status == errSecSuccess else {
            throw XMPPConnectionError.tlsUpgradeFailed("SSLSetConnection failed: \(status)")
        }

        status = SSLSetPeerDomainName(ctx, serverName, serverName.utf8.count)
        guard status == errSecSuccess else {
            throw XMPPConnectionError.tlsUpgradeFailed("SSLSetPeerDomainName failed: \(status)")
        }

        return ctx
    }

    private func sendSSL(ctx: SSLContext, bytes: [UInt8]) throws {
        var totalWritten = 0
        while totalWritten < bytes.count {
            var written = 0
            let remaining = bytes.count - totalWritten
            let status = bytes.withUnsafeBufferPointer { buf in
                SSLWrite(ctx, buf.baseAddress! + totalWritten, remaining, &written)
            }
            guard status == errSecSuccess || status == errSSLWouldBlock else {
                throw XMPPConnectionError.sendFailed("SSLWrite failed: \(status)")
            }
            if written == 0 {
                try waitForWritable()
            }
            totalWritten += written
        }
    }

    private func sendPlain(bytes: [UInt8]) throws {
        try bytes.withUnsafeBufferPointer { buf in
            var totalSent = 0
            while totalSent < bytes.count {
                let sent = Darwin.send(fd, buf.baseAddress! + totalSent, bytes.count - totalSent, 0)
                if sent < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        try waitForWritable()
                        continue
                    }
                    throw XMPPConnectionError.sendFailed("send() failed: \(errno)")
                }
                guard sent > 0 else {
                    throw XMPPConnectionError.sendFailed("send() returned 0")
                }
                totalSent += sent
            }
        }
    }

    private func waitForWritable() throws {
        var pollFd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let result = Darwin.poll(&pollFd, 1, 5000)
        guard result > 0 else {
            throw XMPPConnectionError.sendFailed("Socket not writable (poll returned \(result))")
        }
    }

    private func resolveAndConnect(host: String, port: UInt16) async throws -> Int32 {
        try await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM

            var result: UnsafeMutablePointer<addrinfo>?
            let portStr = String(port)
            let err = getaddrinfo(host, portStr, &hints, &result)
            guard err == 0, let addrList = result else {
                throw XMPPConnectionError.connectionFailed("getaddrinfo failed: \(err)")
            }
            defer { freeaddrinfo(addrList) }

            var lastError: Int32 = 0
            var addr: UnsafeMutablePointer<addrinfo>? = addrList
            while let ai = addr {
                let socketFD = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
                guard socketFD >= 0 else {
                    addr = ai.pointee.ai_next
                    continue
                }

                if Darwin.connect(socketFD, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    return socketFD
                }
                lastError = errno
                close(socketFD)
                addr = ai.pointee.ai_next
            }
            throw XMPPConnectionError.connectionFailed("connect() failed: \(lastError)")
        }.value
    }

    private func startReceiving() {
        let fdCopy = fd
        let continuation = receivedContinuation
        receiveTask = Task.detached { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            while !Task.isCancelled {
                let count: Int
                if let ctx = await self?.sslContext {
                    var read = 0
                    let status = SSLRead(ctx, &buffer, buffer.count, &read)
                    if status == errSSLWouldBlock && read == 0 {
                        try? await Task.sleep(for: .milliseconds(10))
                        continue
                    }
                    guard status == errSecSuccess || status == errSSLWouldBlock || status == errSSLClosedGraceful else {
                        break
                    }
                    if read == 0 { break }
                    count = read
                } else {
                    let result = recv(fdCopy, &buffer, buffer.count, 0)
                    if result == 0 { break }
                    if result < 0 {
                        if errno == EAGAIN || errno == EWOULDBLOCK {
                            try? await Task.sleep(for: .milliseconds(10))
                            continue
                        }
                        break
                    }
                    count = result
                }
                continuation.yield(Array(buffer[..<count]))
            }
            if !Task.isCancelled {
                continuation.finish()
            }
        }
    }
}

// MARK: - SSL Trust Validation

/// Validates the server certificate chain after a successful TLS handshake.
///
/// Secure Transport requires the application to explicitly evaluate the peer trust
/// chain. Without this, a self-signed or invalid certificate would be silently accepted.
private func validatePeerTrust(ctx: SSLContext) throws {
    var trust: SecTrust?
    let status = SSLCopyPeerTrust(ctx, &trust)
    guard status == errSecSuccess, let trust else {
        throw XMPPConnectionError.tlsUpgradeFailed("Failed to copy peer trust: OSStatus \(status)")
    }

    var trustError: CFError?
    guard SecTrustEvaluateWithError(trust, &trustError) else {
        let reason = (trustError as Error?)?.localizedDescription ?? "Unknown trust evaluation error"
        throw XMPPConnectionError.tlsUpgradeFailed("Peer trust evaluation failed: \(reason)")
    }
}

// MARK: - SSL I/O Callbacks

/// Reads exactly the requested number of bytes from the socket.
///
/// Secure Transport expects the read callback to fill the entire buffer on success.
/// A single `recv()` call may return fewer bytes than requested (partial read), so
/// we loop until the buffer is full or an error occurs.
private func posixSSLRead(
    connection: SSLConnectionRef,
    data: UnsafeMutableRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fd = connection.assumingMemoryBound(to: Int32.self).pointee
    let requested = dataLength.pointee
    var totalRead = 0

    while totalRead < requested {
        let result = recv(fd, data + totalRead, requested - totalRead, 0)
        if result > 0 {
            totalRead += result
        } else if result == 0 {
            dataLength.pointee = totalRead
            return totalRead > 0 ? errSecSuccess : errSSLClosedGraceful
        } else {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if totalRead > 0 {
                    // Partial data already buffered — report what we have.
                    // On a blocking socket this shouldn't happen, but handle
                    // it gracefully: return partial data and signal would-block
                    // so the caller can retry.
                    dataLength.pointee = totalRead
                    return errSSLWouldBlock
                }
                dataLength.pointee = 0
                return errSSLWouldBlock
            }
            dataLength.pointee = totalRead
            return errSecIO
        }
    }

    dataLength.pointee = totalRead
    return errSecSuccess
}

/// Writes exactly the requested number of bytes to the socket.
///
/// A single `send()` call may write fewer bytes than requested (partial write), so
/// we loop until all bytes are sent or an error occurs.
private func posixSSLWrite(
    connection: SSLConnectionRef,
    data: UnsafeRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fd = connection.assumingMemoryBound(to: Int32.self).pointee
    let requested = dataLength.pointee
    var totalWritten = 0

    while totalWritten < requested {
        let result = Darwin.send(fd, data + totalWritten, requested - totalWritten, 0)
        if result > 0 {
            totalWritten += result
        } else { // send() returning 0 or negative — treat as error
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if totalWritten > 0 {
                    dataLength.pointee = totalWritten
                    return errSSLWouldBlock
                }
                dataLength.pointee = 0
                return errSSLWouldBlock
            }
            dataLength.pointee = totalWritten
            return errSecIO
        }
    }

    dataLength.pointee = totalWritten
    return errSecSuccess
}
