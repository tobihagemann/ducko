import Darwin
import Testing
@testable import DuckoXMPP

enum SOCKS5ListenerTests {
    struct StartListening {
        @Test("Listener starts on ephemeral port")
        func ephemeralPort() async throws {
            let listener = SOCKS5Listener()
            let port = try await listener.start()
            #expect(port > 0)
            await listener.close()
        }

        @Test("Listener rejects double start")
        func doubleStart() async throws {
            let listener = SOCKS5Listener()
            _ = try await listener.start()
            await #expect(throws: SOCKS5Listener.ListenerError.self) {
                try await listener.start()
            }
            await listener.close()
        }
    }

    struct Handshake {
        @Test("Server handshake with correct DST.ADDR succeeds")
        func correctDstAddr() async throws {
            let listener = SOCKS5Listener()
            let port = try await listener.start()

            let dstAddr = SOCKS5Connection.destinationAddress(
                sid: "test-sid",
                initiatorJID: "alice@example.com/res",
                targetJID: "bob@example.com/res"
            )

            // Spawn listener accept task
            let acceptTask = Task {
                try await listener.accept(expectedDstAddr: dstAddr, timeout: 5)
            }

            // Connect with a SOCKS5Connection client
            let client = SOCKS5Connection()
            try await client.connect(
                host: "127.0.0.1",
                port: port,
                destinationAddress: dstAddr
            )

            // Listener should return a valid connection
            let serverConn = try await acceptTask.value

            // Clean up
            await client.close()
            await serverConn.close()
            await listener.close()
        }

        @Test("Server handshake with wrong DST.ADDR fails")
        func wrongDstAddr() async throws {
            let listener = SOCKS5Listener()
            let port = try await listener.start()

            let correctAddr = SOCKS5Connection.destinationAddress(
                sid: "test-sid",
                initiatorJID: "alice@example.com/res",
                targetJID: "bob@example.com/res"
            )
            let wrongAddr = SOCKS5Connection.destinationAddress(
                sid: "wrong-sid",
                initiatorJID: "alice@example.com/res",
                targetJID: "bob@example.com/res"
            )

            // Spawn listener accept with the correct address expectation
            let acceptTask = Task {
                try await listener.accept(expectedDstAddr: correctAddr, timeout: 5)
            }

            // Client connects with wrong address — the client handshake will
            // fail because the server will reject the DST.ADDR and close the socket
            let client = SOCKS5Connection()
            do {
                try await client.connect(
                    host: "127.0.0.1",
                    port: port,
                    destinationAddress: wrongAddr
                )
            } catch {
                // Expected — server closed the connection
            }

            // Listener accept should fail
            await #expect(throws: Error.self) {
                try await acceptTask.value
            }

            await client.close()
            await listener.close()
        }
    }

    struct DataTransfer {
        @Test("Data round-trip through listener-accepted connection")
        func roundTrip() async throws {
            let listener = SOCKS5Listener()
            let port = try await listener.start()

            let dstAddr = SOCKS5Connection.destinationAddress(
                sid: "round-trip-sid",
                initiatorJID: "sender@example.com/a",
                targetJID: "receiver@example.com/b"
            )

            let acceptTask = Task {
                try await listener.accept(expectedDstAddr: dstAddr, timeout: 5)
            }

            let client = SOCKS5Connection()
            try await client.connect(
                host: "127.0.0.1",
                port: port,
                destinationAddress: dstAddr
            )

            let serverConn = try await acceptTask.value

            // Client sends data, server receives
            let testData: [UInt8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F] // "Hello"
            try await client.send(testData)
            let received = try await serverConn.receive(testData.count)
            #expect(received == testData)

            // Server sends data back, client receives
            let replyData: [UInt8] = [0x57, 0x6F, 0x72, 0x6C, 0x64] // "World"
            try await serverConn.send(replyData)
            let reply = try await client.receive(replyData.count)
            #expect(reply == replyData)

            await client.close()
            await serverConn.close()
            await listener.close()
        }
    }

    struct CleanUp {
        @Test("Close listener before accept returns")
        func closeBeforeAccept() async throws {
            let listener = SOCKS5Listener()
            _ = try await listener.start()

            let acceptTask = Task {
                try await listener.accept(expectedDstAddr: "dummy", timeout: 2)
            }

            // Give accept a moment to start, then close the listener
            try? await Task.sleep(for: .milliseconds(100))
            await listener.close()

            // Accept should fail (socket closed)
            await #expect(throws: Error.self) {
                try await acceptTask.value
            }
        }
    }
}
