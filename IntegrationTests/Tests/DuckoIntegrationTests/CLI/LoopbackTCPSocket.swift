import Darwin

enum LoopbackTCPSocketError: Error, CustomStringConvertible {
    case socketSetupFailed(operation: String, errno: Int32)

    var description: String {
        switch self {
        case let .socketSetupFailed(operation, errno):
            "LoopbackTCPSocketError.socketSetupFailed(\(operation), errno: \(errno))"
        }
    }
}

/// Creates a TCP socket bound to `127.0.0.1:0` and resolves the kernel-assigned
/// port. On success the caller owns `fd` and must `close` it; on any failure the
/// fd is closed and the failing syscall is named in the thrown error.
func bindLoopbackTCPSocket(nonBlocking: Bool = false) throws -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LoopbackTCPSocketError.socketSetupFailed(operation: "socket", errno: errno) }

    if nonBlocking {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(fd)
            throw LoopbackTCPSocketError.socketSetupFailed(operation: "fcntl", errno: errno)
        }
    }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0

    let bound = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else {
        close(fd)
        throw LoopbackTCPSocketError.socketSetupFailed(operation: "bind", errno: errno)
    }

    var resolved = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &resolved) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        }
    }
    guard named == 0 else {
        close(fd)
        throw LoopbackTCPSocketError.socketSetupFailed(operation: "getsockname", errno: errno)
    }

    return (fd, UInt16(bigEndian: resolved.sin_port))
}
