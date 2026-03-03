import CryptoKit
import Testing
@testable import DuckoXMPP

enum SOCKS5ConnectionTests {
    struct DestinationAddressHash {
        @Test("SHA-1 hash is 40-char lowercase hex")
        func hashFormat() {
            let result = SOCKS5Connection.destinationAddress(sid: "abc", initiatorJID: "a@b/c", targetJID: "d@e/f")
            #expect(result.count == 40)
            #expect(result == result.lowercased())
            let allHex = result.allSatisfy(\.isHexDigit)
            #expect(allHex)
        }

        @Test("Deterministic — same inputs produce same output")
        func deterministic() {
            let a = SOCKS5Connection.destinationAddress(sid: "sid-1", initiatorJID: "alice@example.com/res", targetJID: "bob@example.com/res")
            let b = SOCKS5Connection.destinationAddress(sid: "sid-1", initiatorJID: "alice@example.com/res", targetJID: "bob@example.com/res")
            #expect(a == b)
        }

        @Test("Different inputs produce different hashes")
        func differentInputs() {
            let a = SOCKS5Connection.destinationAddress(sid: "sid-1", initiatorJID: "alice@a.com/r", targetJID: "bob@b.com/r")
            let b = SOCKS5Connection.destinationAddress(sid: "sid-2", initiatorJID: "alice@a.com/r", targetJID: "bob@b.com/r")
            #expect(a != b)
        }

        @Test("Cross-check with CryptoKit SHA-1")
        func crossCheck() {
            let sid = "test-sid"
            let initiator = "user@example.com/abc"
            let target = "peer@example.com/xyz"
            let input = sid + initiator + target
            let digest = Insecure.SHA1.hash(data: Array(input.utf8))
            let expected = digest.map { byte in
                byte < 16 ? "0" + String(byte, radix: 16) : String(byte, radix: 16)
            }.joined()

            let result = SOCKS5Connection.destinationAddress(sid: sid, initiatorJID: initiator, targetJID: target)
            #expect(result == expected)
        }
    }

    struct HandshakeByteSequence {
        @Test("Greeting bytes are correct")
        func greetingBytes() {
            let expected: [UInt8] = [0x05, 0x01, 0x00]
            #expect(SOCKS5Connection.greetingBytes == expected)
        }
    }

    struct ConnectRequestBytes {
        @Test("Connect request has correct structure")
        func structure() {
            let addr = "abcdef0123456789abcdef0123456789abcdef01"
            let request = SOCKS5Connection.connectRequest(destinationAddress: addr)

            #expect(request[0] == 0x05) // VER
            #expect(request[1] == 0x01) // CMD = CONNECT
            #expect(request[2] == 0x00) // RSV
            #expect(request[3] == 0x03) // ATYP = DOMAINNAME

            let addrLen = Int(request[4])
            #expect(addrLen == addr.utf8.count)

            let addrBytes = Array(request[5 ..< 5 + addrLen])
            #expect(addrBytes == Array(addr.utf8))

            // PORT = 0x0000
            #expect(request[5 + addrLen] == 0x00)
            #expect(request[5 + addrLen + 1] == 0x00)

            // Total length
            let expectedLen = 5 + addrLen + 2
            #expect(request.count == expectedLen)
        }
    }

    struct ResponseValidation {
        @Test("validateGreetingResponse accepts valid response")
        func validGreeting() throws {
            try SOCKS5Connection.validateGreetingResponse([0x05, 0x00])
        }

        @Test("validateGreetingResponse throws on rejected method")
        func rejectedMethod() {
            #expect(throws: SOCKS5Connection.SOCKS5Error.self) {
                try SOCKS5Connection.validateGreetingResponse([0x05, 0xFF])
            }
        }

        @Test("validateGreetingResponse throws on wrong length")
        func wrongLength() {
            #expect(throws: SOCKS5Connection.SOCKS5Error.self) {
                try SOCKS5Connection.validateGreetingResponse([0x05])
            }
        }

        @Test("validateConnectResponse accepts success reply")
        func validConnect() throws {
            try SOCKS5Connection.validateConnectResponse([0x05, 0x00, 0x00, 0x01])
        }

        @Test("validateConnectResponse throws on failure reply")
        func failedConnect() {
            #expect(throws: SOCKS5Connection.SOCKS5Error.self) {
                try SOCKS5Connection.validateConnectResponse([0x05, 0x01, 0x00, 0x01])
            }
        }
    }

    struct CandidateSorting {
        @Test("Candidates sorted by priority descending")
        func sortByPriority() {
            let candidates = [
                SOCKS5Transport.Candidate(cid: "low", host: "a", port: 1, jid: "a@b", priority: 10, type: .proxy),
                SOCKS5Transport.Candidate(cid: "high", host: "b", port: 2, jid: "b@c", priority: 100, type: .proxy),
                SOCKS5Transport.Candidate(cid: "mid", host: "c", port: 3, jid: "c@d", priority: 50, type: .direct)
            ]
            let sorted = candidates.sorted { $0.priority > $1.priority }
            #expect(sorted[0].cid == "high")
            #expect(sorted[1].cid == "mid")
            #expect(sorted[2].cid == "low")
        }
    }
}
