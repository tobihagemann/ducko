import Foundation
import Testing
@testable import DuckoCore

enum AdiumHTMLLogParserTests {
    // MARK: - Test Data

    private static let sampleHTML = """
    <div class="send"><span class="timestamp">10:47:52 PM</span> <span class="sender">101494097: </span><pre class="message">hello world</pre></div>
    <div class="receive"><span class="timestamp">10:48:08 PM</span> <span class="sender">52333244: </span><pre class="message">hi there</pre></div>
    <div class="status">User disconnected (4:06:39 PM)</div>
    """

    private static let htmlEntitiesHTML = """
    <div class="send"><span class="timestamp">10:00:00 PM</span> <span class="sender">user: </span><pre class="message">caf&#233; &amp; cr&#232;me</pre></div>
    """

    private static let fileDate: Date = {
        var components = DateComponents()
        components.year = 2006
        components.month = 5
        components.day = 9
        return Calendar.current.date(from: components)!
    }()

    // MARK: - Parsing Tests

    struct BasicParsing {
        @Test
        func `Extracts send and receive messages, skips status`() {
            let entries = AdiumHTMLLogParser.parse(
                data: Data(sampleHTML.utf8),
                fileDate: fileDate,
                accountUID: "101494097"
            )
            #expect(entries.count == 2)
        }

        @Test
        func `Extracts sender identifiers`() {
            let entries = AdiumHTMLLogParser.parse(
                data: Data(sampleHTML.utf8),
                fileDate: fileDate,
                accountUID: "101494097"
            )
            #expect(entries[0].sender == "101494097")
            #expect(entries[1].sender == "52333244")
        }

        @Test
        func `Extracts message body`() {
            let entries = AdiumHTMLLogParser.parse(
                data: Data(sampleHTML.utf8),
                fileDate: fileDate,
                accountUID: "101494097"
            )
            #expect(entries[0].body == "hello world")
            #expect(entries[1].body == "hi there")
        }

        @Test
        func `Combines file date with timestamp`() {
            let entries = AdiumHTMLLogParser.parse(
                data: Data(sampleHTML.utf8),
                fileDate: fileDate,
                accountUID: "101494097"
            )
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: entries[0].timestamp)
            #expect(components.year == 2006)
            #expect(components.month == 5)
            #expect(components.day == 9)
            #expect(components.hour == 22)
            #expect(components.minute == 47)
            #expect(components.second == 52)
        }

        @Test
        func `No htmlBody for HTML format logs`() {
            let entries = AdiumHTMLLogParser.parse(
                data: Data(sampleHTML.utf8),
                fileDate: fileDate,
                accountUID: "101494097"
            )
            #expect(entries[0].htmlBody == nil)
        }
    }

    struct HTMLEntities {
        @Test
        func `Decodes HTML entities in body`() throws {
            let entries = AdiumHTMLLogParser.parse(
                data: Data(htmlEntitiesHTML.utf8),
                fileDate: fileDate,
                accountUID: "user"
            )
            let entry = try #require(entries.first)
            #expect(entry.body == "café & crème")
        }
    }

    struct DateFromFilename {
        @Test
        func `Extracts date from standard filename`() throws {
            let date = try #require(AdiumHTMLLogParser.dateFromFilename("52333244 (2006-05-09).AdiumHTMLLog"))
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            #expect(components.year == 2006)
            #expect(components.month == 5)
            #expect(components.day == 9)
        }

        @Test
        func `Extracts date from HTML filename`() throws {
            let date = try #require(AdiumHTMLLogParser.dateFromFilename("buddy (2007-01-15).html"))
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            #expect(components.year == 2007)
            #expect(components.month == 1)
            #expect(components.day == 15)
        }

        @Test
        func `Returns nil for filename without date`() {
            let date = AdiumHTMLLogParser.dateFromFilename("nodatehere.html")
            #expect(date == nil)
        }
    }

    struct EdgeCases {
        @Test
        func `Returns empty for empty data`() {
            let entries = AdiumHTMLLogParser.parse(data: Data(), fileDate: fileDate, accountUID: "user")
            #expect(entries.isEmpty)
        }

        @Test
        func `Returns empty for non-HTML content`() {
            let entries = AdiumHTMLLogParser.parse(data: Data("just plain text".utf8), fileDate: fileDate, accountUID: "user")
            #expect(entries.isEmpty)
        }
    }
}
