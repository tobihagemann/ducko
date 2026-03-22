import Foundation
import Testing
@testable import DuckoCore

enum AdiumXMLLogParserTests {
    // MARK: - Test Data

    private static let sampleXML = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="saibot@exnet.me" service="Jabber" adiumversion="1.5.11b2" buildid="10a6d9caba1b">
    <event type="windowOpened" sender="saibot@exnet.me" time="2016-01-12T00:31:17+0100"></event>
    <message sender="saibot@exnet.me" time="2016-01-12T00:31:17+0100" alias="saibot"><div>hello world</div></message>
    <message sender="mank319@exnet.me" time="2016-01-12T00:31:34+0100" alias="Manuel Kehl"><div><span style="font-family: Helvetica; font-size: 12pt;">oh nice</span></div></message>
    <status type="disconnected" sender="saibot@exnet.me" time="2016-01-12T01:15:45+0100"><div>You have disconnected</div></status>
    <event type="windowClosed" sender="saibot@exnet.me" time="2016-01-12T11:41:19+0100"></event>
    </chat>
    """

    private static let mucXML = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="saibot@exnet.me" service="Jabber">
    <message sender="lobby@conference.exnet.me/mank319" time="2015-09-10T10:55:18+0200" alias="mank319"><div><span style="font-family: Helvetica; font-size: 12pt;">Haha</span></div></message>
    <message sender="lobby@conference.exnet.me/snick3rs" time="2015-09-10T21:35:11+0200" alias="snick3rs"><div><span style="font-family: Helvetica; font-size: 12pt;">hello there</span></div></message>
    </chat>
    """

    private static let autoreplyXML = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="user@example.com" service="Jabber">
    <message sender="user@example.com" time="2016-01-12T00:31:17+0100" auto="true"><div>I am away</div></message>
    </chat>
    """

    private static let linkXML = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="user@example.com" service="Jabber">
    <message sender="user@example.com" time="2016-01-12T00:31:17+0100"><div><a href="https://example.com">https://example.com</a></div></message>
    </chat>
    """

    private static let multilineXML = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="user@example.com" service="Jabber">
    <message sender="user@example.com" time="2016-01-12T00:31:17+0100"><div>line one<br />line two<br />line three</div></message>
    </chat>
    """

    // MARK: - Parsing Tests

    struct BasicParsing {
        @Test
        func `Extracts messages and skips status and events`() {
            let entries = AdiumXMLLogParser.parse(data: Data(sampleXML.utf8))
            #expect(entries.count == 2)
        }

        @Test
        func `Extracts sender and alias`() throws {
            let entries = AdiumXMLLogParser.parse(data: Data(sampleXML.utf8))
            let first = try #require(entries.first)
            #expect(first.sender == "saibot@exnet.me")
            #expect(first.alias == "saibot")
        }

        @Test
        func `Extracts plain text body`() throws {
            let entries = AdiumXMLLogParser.parse(data: Data(sampleXML.utf8))
            let first = try #require(entries.first)
            #expect(first.body == "hello world")
        }

        @Test
        func `Strips HTML from body and preserves in htmlBody`() throws {
            let entries = AdiumXMLLogParser.parse(data: Data(sampleXML.utf8))
            let second = try #require(entries.last)
            #expect(second.body == "oh nice")
            #expect(second.htmlBody != nil)
            let htmlContainsSpan = second.htmlBody?.contains("<span") == true
            #expect(htmlContainsSpan)
        }

        @Test
        func `Parses ISO 8601 timestamps with timezone offset`() throws {
            let entries = AdiumXMLLogParser.parse(data: Data(sampleXML.utf8))
            let first = try #require(entries.first)

            let calendar = Calendar(identifier: .gregorian)
            let components = try calendar.dateComponents(in: #require(TimeZone(secondsFromGMT: 3600)), from: first.timestamp)
            #expect(components.year == 2016)
            #expect(components.month == 1)
            #expect(components.day == 12)
            #expect(components.hour == 0)
            #expect(components.minute == 31)
            #expect(components.second == 17)
        }
    }

    struct MUCParsing {
        @Test
        func `Parses MUC messages with room JID and resource`() throws {
            let entries = AdiumXMLLogParser.parse(data: Data(mucXML.utf8))
            #expect(entries.count == 2)

            let first = try #require(entries.first)
            #expect(first.sender == "lobby@conference.exnet.me/mank319")
            #expect(first.alias == "mank319")
        }
    }

    struct SpecialCases {
        @Test
        func `Detects autoreply messages`() throws {
            let entries = AdiumXMLLogParser.parse(data: Data(autoreplyXML.utf8))
            let entry = try #require(entries.first)
            #expect(entry.isAutoreply)
            #expect(entry.body == "I am away")
        }

        @Test
        func `Preserves links in HTML body`() throws {
            let entries = AdiumXMLLogParser.parse(data: Data(linkXML.utf8))
            let entry = try #require(entries.first)
            #expect(entry.body == "https://example.com")
            let htmlContainsAnchor = entry.htmlBody?.contains("<a href=") == true
            #expect(htmlContainsAnchor)
        }

        @Test
        func `Handles multiline messages with br tags`() throws {
            let entries = AdiumXMLLogParser.parse(data: Data(multilineXML.utf8))
            let entry = try #require(entries.first)
            #expect(entry.body == "line one\nline two\nline three")
        }

        @Test
        func `Returns empty array for empty data`() {
            let entries = AdiumXMLLogParser.parse(data: Data())
            #expect(entries.isEmpty)
        }

        @Test
        func `Returns empty array for malformed XML`() {
            let entries = AdiumXMLLogParser.parse(data: Data("not xml".utf8))
            #expect(entries.isEmpty)
        }
    }

    struct StanzaID {
        @Test
        func `Generates deterministic stanzaID`() {
            let id1 = AdiumXMLLogParser.stanzaID(sourcePath: "path/to/file.xml", messageIndex: 0)
            let id2 = AdiumXMLLogParser.stanzaID(sourcePath: "path/to/file.xml", messageIndex: 0)
            #expect(id1 == id2)
            let startsWithPrefix = id1.hasPrefix("adium:")
            #expect(startsWithPrefix)
        }

        @Test
        func `Different paths produce different stanzaIDs`() {
            let id1 = AdiumXMLLogParser.stanzaID(sourcePath: "path/a.xml", messageIndex: 0)
            let id2 = AdiumXMLLogParser.stanzaID(sourcePath: "path/b.xml", messageIndex: 0)
            #expect(id1 != id2)
        }

        @Test
        func `Different indices produce different stanzaIDs`() {
            let id1 = AdiumXMLLogParser.stanzaID(sourcePath: "path/a.xml", messageIndex: 0)
            let id2 = AdiumXMLLogParser.stanzaID(sourcePath: "path/a.xml", messageIndex: 1)
            #expect(id1 != id2)
        }
    }
}
