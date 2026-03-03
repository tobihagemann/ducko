import Testing
@testable import DuckoXMPP

enum JingleTypesTests {
    struct ActionRawValues {
        @Test("JingleAction raw values match XEP-0166 action names")
        func rawValues() {
            #expect(JingleAction.sessionInitiate.rawValue == "session-initiate")
            #expect(JingleAction.sessionAccept.rawValue == "session-accept")
            #expect(JingleAction.sessionTerminate.rawValue == "session-terminate")
            #expect(JingleAction.transportInfo.rawValue == "transport-info")
            #expect(JingleAction.transportReplace.rawValue == "transport-replace")
            #expect(JingleAction.transportAccept.rawValue == "transport-accept")
            #expect(JingleAction.transportReject.rawValue == "transport-reject")
            #expect(JingleAction.sessionInfo.rawValue == "session-info")
        }
    }

    struct TerminateReasonRawValues {
        @Test("JingleTerminateReason raw values match XEP-0166 reason names")
        func rawValues() {
            #expect(JingleTerminateReason.success.rawValue == "success")
            #expect(JingleTerminateReason.decline.rawValue == "decline")
            #expect(JingleTerminateReason.cancel.rawValue == "cancel")
            #expect(JingleTerminateReason.busy.rawValue == "busy")
            #expect(JingleTerminateReason.timeout.rawValue == "timeout")
            #expect(JingleTerminateReason.connectivityError.rawValue == "connectivity-error")
            #expect(JingleTerminateReason.failedTransport.rawValue == "failed-transport")
        }
    }

    struct FileDescriptionParsing {
        @Test("Parses JingleFileDescription from XML element")
        func parsesDescription() {
            var file = XMLElement(name: "file")
            file.setChildText(named: "name", to: "test.txt")
            file.setChildText(named: "size", to: "1024")
            file.setChildText(named: "media-type", to: "text/plain")
            file.setChildText(named: "date", to: "2024-01-01T00:00:00Z")

            var hashElement = XMLElement(name: "hash", namespace: "urn:xmpp:hashes:2", attributes: ["algo": "sha-256"])
            hashElement.addText("abc123")
            file.addChild(hashElement)

            var description = XMLElement(name: "description", namespace: XMPPNamespaces.jingleFileTransfer)
            description.addChild(file)

            let parsed = JingleFileDescription(from: description)
            #expect(parsed != nil)
            #expect(parsed?.name == "test.txt")
            #expect(parsed?.size == 1024)
            #expect(parsed?.mediaType == "text/plain")
            #expect(parsed?.hash == "abc123")
            #expect(parsed?.date == "2024-01-01T00:00:00Z")
        }
    }

    struct FileDescriptionRoundTrip {
        @Test("JingleFileDescription survives parse → toXML → parse round-trip")
        func roundTrip() {
            let original = JingleFileDescription(
                name: "photo.jpg",
                size: 5000,
                mediaType: "image/jpeg",
                hash: "deadbeef",
                date: "2024-06-15T12:00:00Z"
            )

            let xml = original.toXML()
            let parsed = JingleFileDescription(from: xml)
            #expect(parsed != nil)
            #expect(parsed?.name == original.name)
            #expect(parsed?.size == original.size)
            #expect(parsed?.mediaType == original.mediaType)
            #expect(parsed?.hash == original.hash)
            #expect(parsed?.date == original.date)
        }
    }

    struct SOCKS5TransportParsing {
        @Test("Parses SOCKS5Transport with candidates from XML")
        func parsesTransport() {
            let candidate = XMLElement(
                name: "candidate",
                attributes: [
                    "cid": "c1",
                    "host": "192.168.1.1",
                    "port": "1234",
                    "jid": "user@example.com/res",
                    "priority": "100",
                    "type": "direct"
                ]
            )
            var transport = XMLElement(
                name: "transport",
                namespace: XMPPNamespaces.jingleS5B,
                attributes: ["sid": "s5b-sid"]
            )
            transport.addChild(candidate)

            let parsed = SOCKS5Transport(from: transport)
            #expect(parsed != nil)
            #expect(parsed?.sid == "s5b-sid")
            let candidateCount = parsed?.candidates.count
            #expect(candidateCount == 1)
            #expect(parsed?.candidates.first?.cid == "c1")
            #expect(parsed?.candidates.first?.host == "192.168.1.1")
            #expect(parsed?.candidates.first?.port == 1234)
            #expect(parsed?.candidates.first?.jid == "user@example.com/res")
            #expect(parsed?.candidates.first?.priority == 100)
            #expect(parsed?.candidates.first?.type == .direct)
        }
    }

    struct SOCKS5TransportRoundTrip {
        @Test("SOCKS5Transport survives round-trip")
        func roundTrip() {
            let original = SOCKS5Transport(
                sid: "s5b-123",
                candidates: [
                    .init(cid: "c1", host: "10.0.0.1", port: 5000, jid: "a@b.com/r", priority: 200, type: .direct),
                    .init(cid: "c2", host: "proxy.example.com", port: 1080, jid: "proxy@b.com", priority: 50, type: .proxy)
                ]
            )

            let xml = original.toXML()
            let parsed = SOCKS5Transport(from: xml)
            #expect(parsed != nil)
            #expect(parsed?.sid == original.sid)
            let candidateCount = parsed?.candidates.count
            #expect(candidateCount == 2)
            #expect(parsed?.candidates[0].cid == "c1")
            #expect(parsed?.candidates[0].type == .direct)
            #expect(parsed?.candidates[1].cid == "c2")
            #expect(parsed?.candidates[1].type == .proxy)
        }
    }

    struct IBBTransportParsing {
        @Test("Parses IBBTransport from XML")
        func parsesTransport() {
            let transport = XMLElement(
                name: "transport",
                namespace: XMPPNamespaces.jingleIBB,
                attributes: ["sid": "ibb-sid", "block-size": "4096"]
            )

            let parsed = IBBTransport(from: transport)
            #expect(parsed != nil)
            #expect(parsed?.sid == "ibb-sid")
            #expect(parsed?.blockSize == 4096)
        }
    }

    struct IBBTransportRoundTrip {
        @Test("IBBTransport survives round-trip")
        func roundTrip() {
            let original = IBBTransport(sid: "ibb-456", blockSize: 8192)
            let xml = original.toXML()
            let parsed = IBBTransport(from: xml)
            #expect(parsed != nil)
            #expect(parsed?.sid == original.sid)
            #expect(parsed?.blockSize == original.blockSize)
        }
    }

    struct ContentParsing {
        @Test("Parses full JingleContent with description and S5B transport")
        func parsesContent() {
            var file = XMLElement(name: "file")
            file.setChildText(named: "name", to: "doc.pdf")
            file.setChildText(named: "size", to: "2048")

            var description = XMLElement(name: "description", namespace: XMPPNamespaces.jingleFileTransfer)
            description.addChild(file)

            let transport = XMLElement(
                name: "transport",
                namespace: XMPPNamespaces.jingleS5B,
                attributes: ["sid": "t-sid"]
            )

            var content = XMLElement(name: "content", attributes: ["creator": "initiator", "name": "a-file-offer"])
            content.addChild(description)
            content.addChild(transport)

            let parsed = JingleContent(from: content)
            #expect(parsed != nil)
            #expect(parsed?.name == "a-file-offer")
            #expect(parsed?.creator == "initiator")
            #expect(parsed?.description.name == "doc.pdf")
            #expect(parsed?.description.size == 2048)
            if case let .socks5(s5b) = parsed?.transport {
                #expect(s5b.sid == "t-sid")
            } else {
                Issue.record("Expected SOCKS5 transport")
            }
        }
    }

    struct ContentRoundTrip {
        @Test("JingleContent survives round-trip")
        func roundTrip() {
            let original = JingleContent(
                name: "file-offer",
                creator: "initiator",
                description: JingleFileDescription(name: "image.png", size: 9999, mediaType: "image/png"),
                transport: .ibb(IBBTransport(sid: "ibb-rt", blockSize: 4096))
            )

            let xml = original.toXML()
            let parsed = JingleContent(from: xml)
            #expect(parsed != nil)
            #expect(parsed?.name == original.name)
            #expect(parsed?.creator == original.creator)
            #expect(parsed?.description.name == original.description.name)
            #expect(parsed?.description.size == original.description.size)
            if case let .ibb(ibb) = parsed?.transport {
                #expect(ibb.sid == "ibb-rt")
                #expect(ibb.blockSize == 4096)
            } else {
                Issue.record("Expected IBB transport")
            }
        }
    }
}
