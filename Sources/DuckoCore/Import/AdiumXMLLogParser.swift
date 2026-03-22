import CryptoKit
import Foundation

/// Parses Adium XML chat log files (`.chatlog/*.xml`) using Foundation's SAX-based XMLParser.
///
/// The XML format uses the ULF namespace `http://purl.org/net/ulf/ns/0.4-02`:
/// ```xml
/// <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="user@example.com" service="Jabber">
///   <message sender="user@example.com" time="2016-01-12T00:31:17+0100" alias="User">
///     <div>Hello world</div>
///   </message>
/// </chat>
/// ```
package enum AdiumXMLLogParser {
    /// Parses an Adium XML chatlog file and returns the extracted message entries.
    static func parse(data: Data) -> [AdiumLogEntry] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    /// Generates a deterministic stanzaID for an Adium import message.
    static func stanzaID(sourcePath: String, messageIndex: Int) -> String {
        let input = "\(sourcePath):\(messageIndex)"
        let hash = SHA256.hash(data: Data(input.utf8))
        let hex = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "adium:\(hex)"
    }
}

// MARK: - XMLParser Delegate

private final class ParserDelegate: NSObject, XMLParserDelegate {
    var entries: [AdiumLogEntry] = []

    private var inMessage = false
    private var inDiv = false
    private var divDepth = 0
    private var currentSender: String?
    private var currentTimestamp: Date?
    private var currentAlias: String?
    private var currentIsAutoreply = false
    private var textBuffer = ""
    private var htmlBuffer = ""

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch elementName {
        case "message":
            inMessage = true
            currentSender = attributes["sender"]
            currentAlias = attributes["alias"]
            currentIsAutoreply = attributes["auto"] == "true"
            currentTimestamp = attributes["time"].flatMap { parseTimestamp($0) }
            textBuffer = ""
            htmlBuffer = ""

        case "div" where inMessage:
            if !inDiv {
                inDiv = true
                divDepth = 1
            } else {
                divDepth += 1
                htmlBuffer += "<div>"
            }

        case "br" where inDiv:
            textBuffer += "\n"
            htmlBuffer += "<br />"

        case "a" where inDiv:
            let href = attributes["href"] ?? ""
            htmlBuffer += "<a href=\"\(escapeHTML(href))\">"

        case "span" where inDiv:
            var tag = "<span"
            if let style = attributes["style"] {
                tag += " style=\"\(escapeHTML(style))\""
            }
            tag += ">"
            htmlBuffer += tag

        default:
            if inDiv {
                htmlBuffer += "<\(elementName)>"
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inDiv {
            textBuffer += string
            htmlBuffer += escapeHTML(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch elementName {
        case "message":
            if inMessage, let sender = currentSender, let timestamp = currentTimestamp {
                let body = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    let html = htmlBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    let entry = AdiumLogEntry(
                        sender: sender,
                        timestamp: timestamp,
                        alias: currentAlias,
                        body: body,
                        htmlBody: html.isEmpty ? nil : html,
                        isAutoreply: currentIsAutoreply
                    )
                    entries.append(entry)
                }
            }
            inMessage = false
            inDiv = false
            divDepth = 0
            currentSender = nil
            currentTimestamp = nil
            currentAlias = nil
            currentIsAutoreply = false

        case "div" where inDiv:
            divDepth -= 1
            if divDepth <= 0 {
                inDiv = false
            } else {
                htmlBuffer += "</div>"
            }

        case "a" where inDiv:
            htmlBuffer += "</a>"

        case "span" where inDiv:
            htmlBuffer += "</span>"

        default:
            if inDiv {
                htmlBuffer += "</\(elementName)>"
            }
        }
    }

    // MARK: - Helpers

    private func parseTimestamp(_ string: String) -> Date? {
        // Adium uses ISO 8601: "2016-01-12T00:31:17+0100"
        // ISO8601DateFormatter expects "+01:00" format, so insert colon if missing
        let normalized: String
        if let plusIndex = string.lastIndex(of: "+"), string.distance(from: plusIndex, to: string.endIndex) == 5 {
            let offset = string[plusIndex...]
            normalized = string[..<plusIndex] + String(offset.prefix(3)) + ":" + String(offset.suffix(2))
        } else if let minusIndex = string.suffix(5).firstIndex(of: "-"),
                  string.distance(from: minusIndex, to: string.endIndex) == 5,
                  string[string.index(before: minusIndex)] != "T" {
            let offset = string[minusIndex...]
            normalized = string[..<minusIndex] + String(offset.prefix(3)) + ":" + String(offset.suffix(2))
        } else {
            normalized = string
        }
        return dateFormatter.date(from: normalized)
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
