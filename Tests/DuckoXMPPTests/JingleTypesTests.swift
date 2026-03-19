import Testing
@testable import DuckoXMPP

enum JingleTypesTests {
    struct ActionRawValues {
        @Test
        func `JingleAction raw values match XEP-0166 action names`() {
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
        @Test
        func `JingleTerminateReason raw values match XEP-0166 reason names`() {
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
        @Test
        func `Parses JingleFileDescription from XML element`() {
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
        @Test
        func `JingleFileDescription survives parse → toXML → parse round-trip`() {
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
            #expect(parsed?.desc == nil)
        }
    }

    struct FileDescriptionDesc {
        @Test
        func `Parses desc element from file description`() {
            var file = XMLElement(name: "file")
            file.setChildText(named: "name", to: "notes.txt")
            file.setChildText(named: "size", to: "512")
            file.setChildText(named: "desc", to: "Meeting notes from today")

            var description = XMLElement(name: "description", namespace: XMPPNamespaces.jingleFileTransfer)
            description.addChild(file)

            let parsed = JingleFileDescription(from: description)
            #expect(parsed?.desc == "Meeting notes from today")
        }

        @Test
        func `Desc survives round-trip`() {
            let original = JingleFileDescription(name: "doc.pdf", size: 1024, desc: "Important document")
            let xml = original.toXML()
            let parsed = JingleFileDescription(from: xml)
            #expect(parsed?.desc == "Important document")
        }

        @Test
        func `Desc is nil when not present`() {
            var file = XMLElement(name: "file")
            file.setChildText(named: "name", to: "test.txt")
            file.setChildText(named: "size", to: "100")

            var description = XMLElement(name: "description", namespace: XMPPNamespaces.jingleFileTransfer)
            description.addChild(file)

            let parsed = JingleFileDescription(from: description)
            #expect(parsed?.desc == nil)
        }
    }

    struct FilenameSanitization {
        @Test(arguments: [
            ("test.txt", "test.txt"),
            ("../../etc/passwd", "passwd"),
            ("/absolute/path/file.pdf", "file.pdf"),
            ("..\\..\\windows\\cmd.exe", "cmd.exe"),
            ("..", "unnamed"),
            (".", "unnamed"),
            ("", "unnamed")
        ])
        func `sanitizeFileName strips path components`(input: String, expected: String) {
            let result = JingleFileDescription.sanitizeFileName(input)
            #expect(result == expected)
        }

        @Test
        func `Parsing sanitizes filename from XML`() {
            var file = XMLElement(name: "file")
            file.setChildText(named: "name", to: "../../../etc/passwd")
            file.setChildText(named: "size", to: "1024")

            var description = XMLElement(name: "description", namespace: XMPPNamespaces.jingleFileTransfer)
            description.addChild(file)

            let parsed = JingleFileDescription(from: description)
            #expect(parsed?.name == "passwd")
        }
    }

    struct SOCKS5TransportParsing {
        @Test
        func `Parses SOCKS5Transport with candidates from XML`() {
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
        @Test
        func `SOCKS5Transport survives round-trip`() {
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
        @Test
        func `Parses IBBTransport from XML`() {
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
        @Test
        func `IBBTransport survives round-trip`() {
            let original = IBBTransport(sid: "ibb-456", blockSize: 8192)
            let xml = original.toXML()
            let parsed = IBBTransport(from: xml)
            #expect(parsed != nil)
            #expect(parsed?.sid == original.sid)
            #expect(parsed?.blockSize == original.blockSize)
        }
    }

    struct ContentParsing {
        @Test
        func `Parses full JingleContent with description and S5B transport`() {
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
        @Test
        func `JingleContent survives round-trip`() {
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

    struct SendersRawValues {
        @Test
        func `JingleContentSenders raw values match XEP-0166 senders names`() {
            #expect(JingleContentSenders.none.rawValue == "none")
            #expect(JingleContentSenders.initiator.rawValue == "initiator")
            #expect(JingleContentSenders.responder.rawValue == "responder")
            #expect(JingleContentSenders.both.rawValue == "both")
        }
    }

    struct ContentSendersParsing {
        @Test
        func `Parses senders attribute from content element`() {
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

            var content = XMLElement(
                name: "content",
                attributes: ["creator": "initiator", "name": "a-file-offer", "senders": "responder"]
            )
            content.addChild(description)
            content.addChild(transport)

            let parsed = JingleContent(from: content)
            #expect(parsed?.senders == .responder)
            #expect(parsed?.effectiveSenders == .responder)
        }

        @Test
        func `Absent senders parses as nil with effectiveSenders both`() {
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
            #expect(parsed?.senders == nil)
            #expect(parsed?.effectiveSenders == .both)
        }
    }

    struct ContentSendersRoundTrip {
        @Test
        func `JingleContent with senders survives round-trip`() {
            let original = JingleContent(
                name: "file-offer",
                creator: "initiator",
                senders: .responder,
                description: JingleFileDescription(name: "doc.pdf", size: 1024),
                transport: .ibb(IBBTransport(sid: "ibb-1", blockSize: 4096))
            )

            let xml = original.toXML()
            let parsed = JingleContent(from: xml)
            #expect(parsed?.senders == .responder)
        }

        @Test
        func `JingleContent without senders omits attribute in XML`() {
            let original = JingleContent(
                name: "file-offer",
                creator: "initiator",
                description: JingleFileDescription(name: "doc.pdf", size: 1024),
                transport: .ibb(IBBTransport(sid: "ibb-1", blockSize: 4096))
            )

            let xml = original.toXML()
            #expect(xml.attribute("senders") == nil)

            let parsed = JingleContent(from: xml)
            #expect(parsed?.senders == nil)
        }
    }

    struct ContentActionRawValues {
        @Test
        func `JingleAction content action raw values match XEP-0166 names`() {
            #expect(JingleAction.contentAdd.rawValue == "content-add")
            #expect(JingleAction.contentAccept.rawValue == "content-accept")
            #expect(JingleAction.contentReject.rawValue == "content-reject")
            #expect(JingleAction.contentRemove.rawValue == "content-remove")
        }
    }

    struct FileRangeParsing {
        @Test
        func `Parses range with offset and length`() {
            let element = XMLElement(name: "range", attributes: ["offset": "100", "length": "500"])
            let range = JingleFileRange(from: element)
            #expect(range?.offset == 100)
            #expect(range?.length == 500)
        }

        @Test
        func `Parses empty range element`() {
            let element = XMLElement(name: "range")
            let range = JingleFileRange(from: element)
            #expect(range != nil)
            #expect(range?.offset == nil)
            #expect(range?.length == nil)
        }

        @Test
        func `Parses range with offset only`() {
            let element = XMLElement(name: "range", attributes: ["offset": "200"])
            let range = JingleFileRange(from: element)
            #expect(range?.offset == 200)
            #expect(range?.length == nil)
        }

        @Test
        func `Returns nil for non-range element`() {
            let element = XMLElement(name: "file")
            let range = JingleFileRange(from: element)
            #expect(range == nil)
        }
    }

    struct FileRangeRoundTrip {
        @Test
        func `JingleFileRange survives round-trip`() {
            let original = JingleFileRange(offset: 100, length: 500)
            let xml = original.toXML()
            let parsed = JingleFileRange(from: xml)
            #expect(parsed?.offset == 100)
            #expect(parsed?.length == 500)
        }

        @Test
        func `Empty JingleFileRange serializes without attributes`() {
            let original = JingleFileRange()
            let xml = original.toXML()
            #expect(xml.attribute("offset") == nil)
            #expect(xml.attribute("length") == nil)

            let parsed = JingleFileRange(from: xml)
            #expect(parsed != nil)
            #expect(parsed?.offset == nil)
            #expect(parsed?.length == nil)
        }
    }

    struct FileDescriptionWithRange {
        @Test
        func `Parses range from file description XML`() {
            var file = XMLElement(name: "file")
            file.setChildText(named: "name", to: "test.txt")
            file.setChildText(named: "size", to: "1024")
            file.addChild(XMLElement(name: "range", attributes: ["offset": "100", "length": "500"]))

            var description = XMLElement(name: "description", namespace: XMPPNamespaces.jingleFileTransfer)
            description.addChild(file)

            let parsed = JingleFileDescription(from: description)
            #expect(parsed?.range != nil)
            #expect(parsed?.range?.offset == 100)
            #expect(parsed?.range?.length == 500)
        }

        @Test
        func `Range survives file description round-trip`() {
            let original = JingleFileDescription(
                name: "resume.dat", size: 10000,
                range: JingleFileRange(offset: 5000, length: 5000)
            )
            let xml = original.toXML()
            let parsed = JingleFileDescription(from: xml)
            #expect(parsed?.range?.offset == 5000)
            #expect(parsed?.range?.length == 5000)
        }

        @Test
        func `Range is nil when not present in file description`() {
            let original = JingleFileDescription(name: "test.txt", size: 100)
            let xml = original.toXML()
            let parsed = JingleFileDescription(from: xml)
            #expect(parsed?.range == nil)
        }
    }
}
