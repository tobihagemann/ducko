import Darwin
import Foundation
import os

/// An HTTP/1.1 responder on 127.0.0.1 that answers each connection with the next scripted response (the last one
/// repeats), so a download through `URLSession` can be driven without a network.
final class LoopbackHTTPServer: Sendable {
    struct Response: Sendable {
        /// How the body's end is marked, which is what decides whether a body cut short can pass for a whole one.
        enum Framing: Sendable {
            /// A `Content-Length` matching the body.
            case contentLength
            /// A `Content-Length` of `declared`, whatever the body's own length.
            case declaredLength(Int)
            /// `Transfer-Encoding: chunked`, ended by the terminating chunk or, without it, by closing the connection.
            case chunked(terminated: Bool)
            /// No length at all, so only the closed connection ends the body.
            case closeDelimited
        }

        let status: Int
        let body: [UInt8]
        var framing: Framing = .contentLength
        var extraHeaders: [String] = []
    }

    let port: UInt16
    private let fd: Int32
    private let responses: OSAllocatedUnfairLock<[Response]>
    private let isHeld = OSAllocatedUnfairLock(initialState: false)
    private let requestHeads = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// The head of every request received so far, in arrival order.
    var requests: [String] {
        requestHeads.withLock { $0 }
    }

    /// Listens on an ephemeral loopback port; `nil` when the socket cannot be set up.
    init?(responses: [Response]) {
        precondition(!responses.isEmpty)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, sockaddrPointer, &length) == 0
            }
        }
        guard bound else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
        self.port = UInt16(bigEndian: address.sin_port)
        self.responses = OSAllocatedUnfairLock(initialState: responses)
        Thread.detachNewThread { [self] in serve() }
    }

    func url(path: String = "report.bin") -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(path)")!
    }

    /// Keeps the next response unsent until `release()`, so a test can act while a download is in flight.
    func hold() {
        isHeld.withLock { $0 = true }
    }

    func release() {
        isHeld.withLock { $0 = false }
    }

    /// Stops accepting connections.
    func stop() {
        release()
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private func serve() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var noSIGPIPE: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
            let head = readRequestHead(client)
            requestHeads.withLock { $0.append(head) }
            while isHeld.withLock({ $0 }) {
                usleep(10000)
            }
            let response = responses.withLock { queue in
                queue.count > 1 ? queue.removeFirst() : queue[0]
            }
            write(response, to: client)
            Darwin.close(client)
        }
    }

    private func readRequestHead(_ client: Int32) -> String {
        var head: [UInt8] = []
        var byte: UInt8 = 0
        while recv(client, &byte, 1, 0) == 1 {
            head.append(byte)
            if head.suffix(4) == [13, 10, 13, 10] { break }
        }
        return String(decoding: head, as: UTF8.self)
    }

    private func write(_ response: Response, to client: Int32) {
        let reason = switch response.status {
        case 200: "OK"
        case 206: "Partial Content"
        case 404: "Not Found"
        default: "Status"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\nConnection: close\r\n"
        var body = response.body
        switch response.framing {
        case .contentLength:
            head += "Content-Length: \(response.body.count)\r\n"
        case let .declaredLength(declared):
            head += "Content-Length: \(declared)\r\n"
        case let .chunked(terminated):
            head += "Transfer-Encoding: chunked\r\n"
            body = Array(String(response.body.count, radix: 16).utf8) + [13, 10] + response.body + [13, 10]
            if terminated {
                body += Array("0\r\n\r\n".utf8)
            }
        case .closeDelimited:
            break
        }
        if response.status == 206 {
            head += "Content-Range: bytes 0-\(max(response.body.count - 1, 0))/\(response.body.count * 10)\r\n"
        }
        for header in response.extraHeaders {
            head += header + "\r\n"
        }
        head += "\r\n"
        let bytes = Array(head.utf8) + body
        _ = bytes.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
    }
}
