import Testing
@testable import DuckoXMPP

enum IBBTransportTests {
    struct Base64RoundTrip {
        @Test(
            "Base64 encode/decode round-trip for IBB block sizes",
            arguments: [1, 100, 4096, 65535]
        )
        func roundTrip(size: Int) {
            var data = [UInt8](repeating: 0, count: size)
            for i in 0 ..< size {
                data[i] = UInt8(i % 256)
            }
            let encoded = Base64.encode(data)
            let decoded = Base64.decode(encoded)
            #expect(decoded == data)
        }
    }

    struct SequenceNumberWrapping {
        @Test("IBB sequence number wraps from UInt16.max to 0")
        func wrapsCorrectly() {
            var seq: UInt16 = 65534
            seq &+= 1
            #expect(seq == 65535)
            seq &+= 1
            #expect(seq == 0)
        }
    }

    struct IBBXMLParsing {
        @Test("IBBTransport parses sid and block-size from XML")
        func parsesAttributes() {
            let element = XMLElement(
                name: "transport",
                namespace: XMPPNamespaces.jingleIBB,
                attributes: ["sid": "ibb-test-123", "block-size": "8192"]
            )
            let transport = IBBTransport(from: element)
            #expect(transport != nil)
            #expect(transport?.sid == "ibb-test-123")
            #expect(transport?.blockSize == 8192)
        }

        @Test("IBBTransport returns nil for missing sid")
        func rejectsNoSID() {
            let element = XMLElement(
                name: "transport",
                namespace: XMPPNamespaces.jingleIBB,
                attributes: ["block-size": "4096"]
            )
            #expect(IBBTransport(from: element) == nil)
        }

        @Test("IBBTransport returns nil for missing block-size")
        func rejectsNoBlockSize() {
            let element = XMLElement(
                name: "transport",
                namespace: XMPPNamespaces.jingleIBB,
                attributes: ["sid": "abc"]
            )
            #expect(IBBTransport(from: element) == nil)
        }
    }

    struct IBBSessionStateAccumulation {
        @Test("IBBSessionState accumulates received data")
        func accumulatesData() throws {
            let peer = try #require(FullJID.parse("peer@example.com/res"))
            var ibbState = IBBSessionState(ibbSID: "ibb-1", blockSize: 4096, peer: peer, expectedSize: 10)

            #expect(ibbState.receivedData.isEmpty)
            #expect(ibbState.nextExpectedSeq == 0)

            ibbState.receivedData.append(contentsOf: [1, 2, 3, 4, 5])
            ibbState.nextExpectedSeq &+= 1

            #expect(ibbState.receivedData.count == 5)
            #expect(ibbState.nextExpectedSeq == 1)

            ibbState.receivedData.append(contentsOf: [6, 7, 8, 9, 10])
            ibbState.nextExpectedSeq &+= 1

            #expect(ibbState.receivedData.count == 10)
            #expect(ibbState.nextExpectedSeq == 2)

            let received = Int64(ibbState.receivedData.count)
            #expect(received >= ibbState.expectedSize)
        }
    }
}
