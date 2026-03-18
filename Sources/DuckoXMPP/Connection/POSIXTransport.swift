import CryptoKit
import Darwin
import Foundation
@preconcurrency import Security

// MARK: - Certificate Signature Hash Algorithm (RFC 5929 §4.1)

/// Hash algorithm to use for `tls-server-end-point` channel binding.
enum CertHashAlgorithm: Equatable {
    case sha256
    case sha384
    case sha512
}

/// Extracts the signature hash algorithm from a DER-encoded X.509 certificate.
///
/// Parses the outer `signatureAlgorithm` OID (after the TBS body) and maps it
/// to the corresponding hash function. Returns `.sha256` as fallback for
/// MD5/SHA-1 signatures or unknown OIDs per RFC 5929 §4.1.
func signatureHashAlgorithm(fromDER der: [UInt8]) -> CertHashAlgorithm {
    // X.509 Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
    // We skip the outer SEQUENCE, skip the TBS SEQUENCE body, then read the OID.
    var offset = 0

    // 1. Outer SEQUENCE
    guard skipTagAndLength(&offset, in: der, expected: 0x30) else { return .sha256 }

    // 2. TBS Certificate SEQUENCE — skip its entire body
    guard skipTagAndBody(&offset, in: der, expected: 0x30) else { return .sha256 }

    // 3. signatureAlgorithm SEQUENCE
    guard skipTagAndLength(&offset, in: der, expected: 0x30) else { return .sha256 }

    // 4. OID inside signatureAlgorithm
    guard offset < der.count, der[offset] == 0x06 else { return .sha256 }
    offset += 1
    guard let oidLength = readDERLength(&offset, in: der),
          offset + oidLength <= der.count else { return .sha256 }
    let oid = Array(der[offset ..< offset + oidLength])

    return hashAlgorithm(forOID: oid)
}

// MARK: DER Parsing Helpers

/// Reads a DER length field starting at `offset`, advancing past it.
private func readDERLength(_ offset: inout Int, in der: [UInt8]) -> Int? {
    guard offset < der.count else { return nil }
    let first = der[offset]
    offset += 1
    if first & 0x80 == 0 {
        return Int(first)
    }
    let numBytes = Int(first & 0x7F)
    guard numBytes > 0, numBytes <= 4, offset + numBytes <= der.count else { return nil }
    var length = 0
    for i in 0 ..< numBytes {
        length = (length << 8) | Int(der[offset + i])
    }
    offset += numBytes
    return length
}

/// Skips past a DER tag byte and its length field, leaving `offset` at the start of the value body.
private func skipTagAndLength(_ offset: inout Int, in der: [UInt8], expected: UInt8) -> Bool {
    guard offset < der.count, der[offset] == expected else { return false }
    offset += 1
    return readDERLength(&offset, in: der) != nil
}

/// Skips past a DER tag byte, its length field, and its entire value body.
private func skipTagAndBody(_ offset: inout Int, in der: [UInt8], expected: UInt8) -> Bool {
    guard offset < der.count, der[offset] == expected else { return false }
    offset += 1
    guard let length = readDERLength(&offset, in: der),
          offset + length <= der.count else { return false }
    offset += length
    return true
}

// MARK: OID → Hash Mapping

/// Maps a DER-encoded OID to the corresponding hash algorithm.
///
/// OID families are identified by prefix, with the trailing byte selecting
/// the specific hash. EdDSA and unknown OIDs fall back to SHA-256.
private func hashAlgorithm(forOID oid: [UInt8]) -> CertHashAlgorithm {
    // RSA: 1.2.840.113549.1.1.{11=SHA256, 12=SHA384, 13=SHA512}
    let rsaPrefix: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01]
    if oid.count == rsaPrefix.count + 1, oid.starts(with: rsaPrefix) {
        return hashFromTrailingByte(oid.last, sha256: 0x0B, sha384: 0x0C, sha512: 0x0D)
    }

    // ECDSA: 1.2.840.10045.4.3.{2=SHA256, 3=SHA384, 4=SHA512}
    let ecdsaPrefix: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03]
    if oid.count == ecdsaPrefix.count + 1, oid.starts(with: ecdsaPrefix) {
        return hashFromTrailingByte(oid.last, sha256: 0x02, sha384: 0x03, sha512: 0x04)
    }

    return .sha256
}

/// Maps the trailing OID byte to a hash algorithm using the given per-family byte values.
private func hashFromTrailingByte(_ byte: UInt8?, sha256: UInt8, sha384: UInt8, sha512: UInt8) -> CertHashAlgorithm {
    switch byte {
    case sha256: return .sha256
    case sha384: return .sha384
    case sha512: return .sha512
    default: return .sha256
    }
}

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
    private(set) var tlsInfo: TLSInfo?

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

    func connectWithTLS(host: String, port: UInt16, serverName: String) async throws {
        guard fd == -1 else { throw XMPPConnectionError.alreadyConnected }

        fd = try await resolveAndConnect(host: host, port: port)
        // Socket stays blocking for SSLHandshake

        let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        fdPtr.pointee = fd

        do {
            try await performSSLHandshake(fdPtr: fdPtr, serverName: serverName, alpnProtocols: ["xmpp-client"])
        } catch {
            sslContext = nil
            tlsInfo = nil
            fdPtr.deallocate()
            close(fd)
            fd = -1
            throw error
        }

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
            try await performSSLHandshake(fdPtr: fdPtr, serverName: serverName)
        } catch {
            sslContext = nil
            tlsInfo = nil
            fdPtr.deallocate()
            throw error
        }

        setNonBlocking(true)
        startReceiving()
    }

    private func performSSLHandshake(
        fdPtr: UnsafeMutablePointer<Int32>,
        serverName: String,
        alpnProtocols: [String]? = nil
    ) async throws {
        let ctx = try configureSSL(fdPtr: fdPtr, serverName: serverName, alpnProtocols: alpnProtocols)

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
        tlsInfo = extractTLSInfo(ctx: ctx)
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

    /// Returns `tls-server-end-point` channel binding data (RFC 5929 §4.1).
    ///
    /// Hashes the server's DER-encoded leaf certificate using the hash algorithm
    /// from the certificate's signature algorithm. Falls back to SHA-256 for
    /// MD5/SHA-1 signatures or unknown algorithms.
    func channelBindingData() -> [UInt8]? {
        guard let ctx = sslContext else { return nil }
        var trust: SecTrust?
        SSLCopyPeerTrust(ctx, &trust)
        guard let trust, SecTrustGetCertificateCount(trust) > 0,
              let cert = SecTrustGetCertificateAtIndex(trust, 0) else { return nil }
        let derData = SecCertificateCopyData(cert) as Data
        let derBytes = [UInt8](derData)
        switch signatureHashAlgorithm(fromDER: derBytes) {
        case .sha256: return Array(SHA256.hash(data: derBytes))
        case .sha384: return Array(SHA384.hash(data: derBytes))
        case .sha512: return Array(SHA512.hash(data: derBytes))
        }
    }

    // MARK: - Private

    private func tearDownSSL() {
        guard let ctx = sslContext else { return }
        SSLClose(ctx)
        var connRef: SSLConnectionRef?
        SSLGetConnection(ctx, &connRef)
        connRef?.assumingMemoryBound(to: Int32.self).deallocate()
        sslContext = nil
        tlsInfo = nil
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
        serverName: String,
        alpnProtocols: [String]? = nil
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

        // RFC 7590: Enforce minimum TLS 1.2 (defense-in-depth)
        _ = SSLSetProtocolVersionMin(ctx, .tlsProtocol12)

        // ALPN is a SHOULD per XEP-0368 — non-fatal if unsupported
        if let alpnProtocols {
            _ = SSLSetALPNProtocols(ctx, alpnProtocols as CFArray)
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

// MARK: - TLS Info Extraction

/// OID for the certificate issuer field in `SecCertificateCopyValues`.
private let certIssuerOID = "2.16.840.1.113741.2.1.1.1.5"

/// OID for the certificate validity period in `SecCertificateCopyValues`.
private let certValidityOID = "2.16.840.1.113741.2.1.1.1.8"

private func extractTLSInfo(ctx: SSLContext) -> TLSInfo {
    var protocol_: SSLProtocol = .sslProtocolUnknown
    SSLGetNegotiatedProtocolVersion(ctx, &protocol_)
    let protocolString = formatSSLProtocol(protocol_)

    var cipher: SSLCipherSuite = 0
    SSLGetNegotiatedCipher(ctx, &cipher)
    let cipherString = formatCipherSuite(cipher)

    // Certificate details
    var trust: SecTrust?
    SSLCopyPeerTrust(ctx, &trust)
    let certInfo = trust.flatMap(extractCertificateInfo)

    return TLSInfo(
        protocolVersion: protocolString,
        cipherSuite: cipherString,
        certificateSubject: certInfo?.subject,
        certificateIssuer: certInfo?.issuer,
        certificateExpiry: certInfo?.expiry,
        certificateSHA256: certInfo?.sha256
    )
}

private struct CertInfo {
    let subject: String?
    let issuer: String?
    let expiry: Date?
    let sha256: String?
}

private func extractCertificateInfo(_ trust: SecTrust) -> CertInfo? {
    guard SecTrustGetCertificateCount(trust) > 0 else { return nil }
    guard let cert = SecTrustGetCertificateAtIndex(trust, 0) else { return nil }

    let subject = SecCertificateCopySubjectSummary(cert) as String?

    // Extract certificate DER data for fingerprint
    let derData = SecCertificateCopyData(cert) as Data
    let sha256Hash = SHA256.hash(data: derData)
    let fingerprint = sha256Hash.map { String(format: "%02X", $0) }.joined(separator: ":")

    // Extract issuer and expiry from certificate values
    var issuer: String?
    var expiry: Date?
    if let values = SecCertificateCopyValues(cert, nil, nil) as? [String: Any] {
        if let issuerEntry = values[certIssuerOID] as? [String: Any],
           let issuerValue = issuerEntry[kSecPropertyKeyValue as String] {
            issuer = issuerValue as? String ?? String(describing: issuerValue)
        }
        if let validityEntry = values[certValidityOID] as? [String: Any],
           let validityArray = validityEntry[kSecPropertyKeyValue as String] as? [[String: Any]] {
            for item in validityArray {
                let label = item[kSecPropertyKeyLabel as String] as? String
                if label == "Not Valid After", let date = item[kSecPropertyKeyValue as String] as? Date {
                    expiry = date
                }
            }
        }
    }

    return CertInfo(subject: subject, issuer: issuer, expiry: expiry, sha256: fingerprint)
}

private func formatSSLProtocol(_ proto: SSLProtocol) -> String {
    switch proto {
    case .tlsProtocol1: "TLS 1.0"
    case .tlsProtocol11: "TLS 1.1"
    case .tlsProtocol12: "TLS 1.2"
    case .tlsProtocol13: "TLS 1.3"
    case .dtlsProtocol1: "DTLS 1.0"
    case .dtlsProtocol12: "DTLS 1.2"
    default: "Unknown"
    }
}

private func formatCipherSuite(_ suite: SSLCipherSuite) -> String {
    // Map common cipher suites to readable names
    switch suite {
    case UInt16(TLS_AES_128_GCM_SHA256): "TLS_AES_128_GCM_SHA256"
    case UInt16(TLS_AES_256_GCM_SHA384): "TLS_AES_256_GCM_SHA384"
    case UInt16(TLS_CHACHA20_POLY1305_SHA256): "TLS_CHACHA20_POLY1305_SHA256"
    case UInt16(TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256): "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
    case UInt16(TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384): "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
    case UInt16(TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256): "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
    case UInt16(TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384): "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
    default: "0x\(String(format: "%04X", suite))"
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
