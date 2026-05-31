import Darwin
import Testing

extension CLIHelperUnitTests {
    struct LoopbackTCPSocketTests {
        @Test
        func `bindLoopbackTCPSocket returns a usable loopback port`() throws {
            let bound = try bindLoopbackTCPSocket()
            defer { close(bound.fd) }
            #expect(bound.fd >= 0)
            #expect(bound.port != 0)
        }

        @Test
        func `bindLoopbackTCPSocket nonBlocking sets O_NONBLOCK`() throws {
            let bound = try bindLoopbackTCPSocket(nonBlocking: true)
            defer { close(bound.fd) }
            #expect(bound.port != 0)
            // Assert the fcntl read succeeded before masking: a `-1` error
            // result would pass `& O_NONBLOCK != 0` and false-green this test.
            let flags = fcntl(bound.fd, F_GETFL, 0)
            #expect(flags >= 0)
            #expect(flags & O_NONBLOCK != 0)
        }

        @Test
        func `bindLoopbackTCPSocket leaves the socket blocking by default`() throws {
            let bound = try bindLoopbackTCPSocket()
            defer { close(bound.fd) }
            let flags = fcntl(bound.fd, F_GETFL, 0)
            #expect(flags >= 0)
            #expect(flags & O_NONBLOCK == 0)
        }
    }
}
