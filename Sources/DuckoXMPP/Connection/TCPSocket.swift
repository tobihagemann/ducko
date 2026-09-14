import Darwin

struct TCPConnectError: Error {
    let reason: String
}

/// Resolves `host` and connects a blocking TCP socket to the first reachable address. The socket has SIGPIPE disabled.
func connectTCPSocket(host: String, port: UInt16) throws(TCPConnectError) -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM

    var result: UnsafeMutablePointer<addrinfo>?
    let err = getaddrinfo(host, String(port), &hints, &result)
    guard err == 0, let addrList = result else {
        throw TCPConnectError(reason: addressInfoErrorText(err))
    }
    defer { freeaddrinfo(addrList) }

    var lastError: Int32 = 0
    var addr: UnsafeMutablePointer<addrinfo>? = addrList
    while let ai = addr {
        let socketFD = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard socketFD >= 0 else {
            lastError = errno
            addr = ai.pointee.ai_next
            continue
        }
        disableSIGPIPE(socketFD)

        if Darwin.connect(socketFD, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
            return socketFD
        }
        lastError = errno
        close(socketFD)
        addr = ai.pointee.ai_next
    }
    throw TCPConnectError(reason: posixErrorText(lastError))
}

/// Makes a send to a reset peer fail with `EPIPE` instead of raising SIGPIPE, which terminates the process by default.
func disableSIGPIPE(_ fd: Int32) {
    var enabled: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}
