import Foundation

/// Parses Adium HTML chat log files (`.html` and `.AdiumHTMLLog`).
///
/// These files contain simple HTML divs with classes indicating direction:
/// ```html
/// <div class="send"><span class="timestamp">10:47:52 PM</span> <span class="sender">user: </span><pre class="message">hello</pre></div>
/// <div class="receive"><span class="timestamp">10:48:08 PM</span> <span class="sender">buddy: </span><pre class="message">hi</pre></div>
/// <div class="status">User disconnected (4:06:39 PM)</div>
/// ```
///
/// Timestamps are time-of-day only — the date comes from the filename.
package enum AdiumHTMLLogParser {
    // MARK: - Cached Formatters

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static let time12Formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let time12NoSecFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let time24Formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let time24NoSecFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Public API

    /// Parses an Adium HTML log file.
    ///
    /// - Parameters:
    ///   - data: The file content as UTF-8 data.
    ///   - fileDate: The date extracted from the filename (used as the base date for time-only timestamps).
    ///   - accountUID: The account UID from the directory structure (reserved for future outgoing detection).
    /// - Returns: Parsed log entries.
    static func parse(data: Data, fileDate: Date, accountUID _: String) -> [AdiumLogEntry] {
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }

        var entries: [AdiumLogEntry] = []
        let scanner = Scanner(string: content)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            // scanUpToString advances the scanner as a side effect; `|| true` ensures the guard succeeds
            // even when no match is found (scanner is already at the target or at end).
            guard scanner.scanUpToString("<div class=\"") != nil || true,
                  scanner.scanString("<div class=\"") != nil else {
                if !scanner.isAtEnd {
                    scanner.currentIndex = content.index(after: scanner.currentIndex)
                }
                continue
            }

            guard let divClass = scanner.scanUpToString("\"") else { continue }
            _ = scanner.scanString("\">")

            switch divClass {
            case "send", "receive":
                if let entry = parseMessageDiv(scanner: scanner, fileDate: fileDate, isSend: divClass == "send") {
                    entries.append(entry)
                }
            default:
                _ = scanner.scanUpToString("</div>")
                _ = scanner.scanString("</div>")
            }
        }

        return entries
    }

    /// Extracts a date from an Adium HTML log filename.
    ///
    /// Filename format: `contactUID (YYYY-MM-DD).html` or `contactUID (YYYY-MM-DD).AdiumHTMLLog`
    static func dateFromFilename(_ filename: String) -> Date? {
        guard let openParen = filename.firstIndex(of: "("),
              let closeParen = filename.firstIndex(of: ")") else {
            return nil
        }

        let dateString = String(filename[filename.index(after: openParen) ..< closeParen])
        return fileDateFormatter.date(from: dateString)
    }

    // MARK: - Private

    private static func parseMessageDiv(scanner: Scanner, fileDate: Date, isSend _: Bool) -> AdiumLogEntry? {
        guard scanner.scanUpToString("<span class=\"timestamp\">") != nil || true,
              scanner.scanString("<span class=\"timestamp\">") != nil,
              let timestampText = scanner.scanUpToString("</span>") else {
            _ = scanner.scanUpToString("</div>")
            _ = scanner.scanString("</div>")
            return nil
        }
        _ = scanner.scanString("</span>")

        guard scanner.scanUpToString("<span class=\"sender\">") != nil || true,
              scanner.scanString("<span class=\"sender\">") != nil,
              let senderText = scanner.scanUpToString("</span>") else {
            _ = scanner.scanUpToString("</div>")
            _ = scanner.scanString("</div>")
            return nil
        }
        _ = scanner.scanString("</span>")

        guard scanner.scanUpToString("<pre class=\"message\">") != nil || true,
              scanner.scanString("<pre class=\"message\">") != nil,
              let bodyHTML = scanner.scanUpToString("</pre>") else {
            _ = scanner.scanUpToString("</div>")
            _ = scanner.scanString("</div>")
            return nil
        }
        _ = scanner.scanString("</pre>")
        _ = scanner.scanUpToString("</div>")
        _ = scanner.scanString("</div>")

        var sender = senderText.trimmingCharacters(in: .whitespaces)
        if sender.hasSuffix(": ") {
            sender = String(sender.dropLast(2))
        } else if sender.hasSuffix(":") {
            sender = String(sender.dropLast(1))
        }

        let body = decodeHTMLEntities(bodyHTML)

        guard let timestamp = combineDateTime(fileDate: fileDate, timeString: timestampText.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        return AdiumLogEntry(
            sender: sender,
            timestamp: timestamp,
            body: body
        )
    }

    private static func combineDateTime(fileDate: Date, timeString: String) -> Date? {
        let calendar = Calendar.current
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: fileDate)

        let timeDate = time12Formatter.date(from: timeString)
            ?? time12NoSecFormatter.date(from: timeString)
            ?? time24Formatter.date(from: timeString)
            ?? time24NoSecFormatter.date(from: timeString)

        guard let timeDate else { return nil }

        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: timeDate)

        var combined = DateComponents()
        combined.year = dateComponents.year
        combined.month = dateComponents.month
        combined.day = dateComponents.day
        combined.hour = timeComponents.hour
        combined.minute = timeComponents.minute
        combined.second = timeComponents.second

        return calendar.date(from: combined)
    }

    private static func decodeHTMLEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        return string
            .replacingNumericEntities()
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

// MARK: - Numeric HTML Entity Decoding

private let numericEntityRegex = try! NSRegularExpression(pattern: "&#(\\d+);") // swiftlint:disable:this force_try

private extension String {
    /// Replaces `&#NNN;` numeric character references with their Unicode characters.
    func replacingNumericEntities() -> String {
        let nsRange = NSRange(startIndex..., in: self)
        var result = self
        for match in numericEntityRegex.matches(in: self, range: nsRange).reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let digitsRange = Range(match.range(at: 1), in: result),
                  let codePoint = UInt32(result[digitsRange]),
                  let scalar = Unicode.Scalar(codePoint) else { continue }
            result.replaceSubrange(fullRange, with: String(scalar))
        }
        return result
    }
}
