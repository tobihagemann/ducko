import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.transcripts")

/// File-based transcript storage using append-only JSONL files, one per UTC date per conversation.
public actor FileTranscriptStore: TranscriptStore {
    private let baseDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// In-memory index mapping stanzaID → (conversationID, date string) for single-file lookups in findMessage/messageExists.
    private var stanzaIndex: [String: (UUID, String)] = [:]

    /// In-memory index mapping serverID → (conversationID, date string) for single-file lookups in findMessage/messageExists.
    private var serverIndex: [String: (UUID, String)] = [:]

    private static let newline = Data("\n".utf8)

    /// Creates a store using the default transcripts directory under `BuildEnvironment.appSupportDirectory`.
    public static func makeDefault() -> FileTranscriptStore {
        let dir = BuildEnvironment.appSupportDirectory.appendingPathComponent("Transcripts", isDirectory: true)
        return FileTranscriptStore(baseDirectory: dir)
    }

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Write

    public func appendMessage(_ message: ChatMessage) async throws {
        let dateString = Self.dateString(for: message.timestamp)
        let fileURL = transcriptFileURL(conversationID: message.conversationID, dateString: dateString)
        let record = TranscriptRecord.from(message)
        try appendRecord(record, to: fileURL, conversationID: message.conversationID)
        if let sid = message.stanzaID {
            stanzaIndex[sid] = (message.conversationID, dateString)
        }
        if let srvid = message.serverID {
            serverIndex[srvid] = (message.conversationID, dateString)
        }
    }

    public func appendMessages(_ messages: [ChatMessage]) async throws {
        guard !messages.isEmpty else { return }

        // Group by (conversationID, date) to minimize file opens
        var grouped: [(key: (UUID, String), messages: [ChatMessage])] = []
        var groupMap: [String: Int] = [:]
        for message in messages {
            let dateString = Self.dateString(for: message.timestamp)
            let key = "\(message.conversationID)|\(dateString)"
            if let index = groupMap[key] {
                grouped[index].messages.append(message)
            } else {
                groupMap[key] = grouped.count
                grouped.append((key: (message.conversationID, dateString), messages: [message]))
            }
        }

        for group in grouped {
            let fileURL = transcriptFileURL(conversationID: group.key.0, dateString: group.key.1)
            try ensureDirectoryExists(for: group.key.0)
            let handle = try fileHandle(for: fileURL)
            defer { try? handle.close() }

            for message in group.messages {
                let record = TranscriptRecord.from(message)
                try writeRecord(record, to: handle)
                if let sid = message.stanzaID {
                    stanzaIndex[sid] = (group.key.0, group.key.1)
                }
                if let srvid = message.serverID {
                    serverIndex[srvid] = (group.key.0, group.key.1)
                }
            }
        }
    }

    public func appendAmendment(_ amendment: TranscriptAmendment, conversationID: UUID) async throws {
        // Amendments must land in the SAME daily file as the target message because
        // applyAmendments runs per-file. If the amendment's date differs from the
        // message's date, the per-file stanzaToID map won't resolve the target and
        // the amendment is silently dropped. Resolve via the in-memory index first
        // (verifying the conversationID matches to reject cross-conversation
        // stanzaID collisions), then scan this conversation's files. Fail closed
        // if the target cannot be located — writing to an arbitrary date file
        // would leave a dangling amendment record that may later attach to an
        // unrelated message with a colliding stanzaID.
        guard let dateString = resolveAmendmentDate(amendment: amendment, conversationID: conversationID) else {
            log.warning("Amendment target not found in conversation \(conversationID): stanzaID=\(amendment.targetStanzaID ?? "nil") serverID=\(amendment.targetServerID ?? "nil")")
            return
        }
        let fileURL = transcriptFileURL(conversationID: conversationID, dateString: dateString)
        let record = TranscriptRecord.from(amendment)
        try appendRecord(record, to: fileURL, conversationID: conversationID)
    }

    /// Locates the date file containing the amendment's target message within `conversationID`.
    /// Returns nil if the target cannot be found in the indexes or by scanning the conversation's files.
    private func resolveAmendmentDate(amendment: TranscriptAmendment, conversationID: UUID) -> String? {
        if let sid = amendment.targetStanzaID,
           let (indexedConv, indexedDate) = stanzaIndex[sid],
           indexedConv == conversationID {
            return indexedDate
        }
        if let srvid = amendment.targetServerID,
           let (indexedConv, indexedDate) = serverIndex[srvid],
           indexedConv == conversationID {
            return indexedDate
        }
        return scanConversationForTarget(amendment: amendment, conversationID: conversationID)
    }

    /// Scans the given conversation's transcript files for the amendment's target message.
    /// Populates the in-memory indexes for any matching message found. Newest files first.
    private func scanConversationForTarget(amendment: TranscriptAmendment, conversationID: UUID) -> String? {
        guard let dateFiles = try? listDateFiles(for: conversationID) else { return nil }
        for (dateString, fileURL) in dateFiles {
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { continue }
            let lines = data.split(separator: UInt8(ascii: "\n"))
            for line in lines {
                guard !line.isEmpty,
                      let record = try? decoder.decode(TranscriptRecord.self, from: Data(line)),
                      case let .message(entry) = record
                else { continue }

                let matches: Bool = if let sid = amendment.targetStanzaID {
                    entry.stanzaID == sid
                } else if let srvid = amendment.targetServerID {
                    entry.serverID == srvid
                } else {
                    false
                }

                if matches {
                    if let sid = entry.stanzaID {
                        stanzaIndex[sid] = (conversationID, dateString)
                    }
                    if let srvid = entry.serverID {
                        serverIndex[srvid] = (conversationID, dateString)
                    }
                    return dateString
                }
            }
        }
        return nil
    }

    // MARK: - Read

    public func fetchMessages(for conversationID: UUID, before: Date?, limit: Int) async throws -> [ChatMessage] {
        let dateFiles = try listDateFiles(for: conversationID)
        var result: [ChatMessage] = []

        for (dateString, fileURL) in dateFiles {
            // Skip files that are entirely after the `before` cutoff
            if let before, let fileDate = Self.parseDate(dateString), fileDate > before {
                continue
            }

            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            let filtered: [ChatMessage] = if let before {
                messages.filter { $0.timestamp < before }
            } else {
                messages
            }

            result.append(contentsOf: filtered)
            if result.count >= limit { break }
        }

        // Sort by timestamp descending (newest first), take limit
        result.sort { $0.timestamp > $1.timestamp }
        return Array(result.prefix(limit))
    }

    public func fetchMessages(for conversationID: UUID, on date: Date) async throws -> [ChatMessage] {
        let dateStr = Self.dateString(for: date)
        let fileURL = transcriptFileURL(conversationID: conversationID, dateString: dateStr)
        return try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
    }

    // MARK: - Lookup

    public func findMessage(stanzaID: String, conversationID: UUID) async throws -> ChatMessage? {
        // Fast path: check stanza index to read only one file. Verify the indexed
        // conversationID matches — stanzaIDs can collide across conversations and
        // last-write-wins would otherwise probe the wrong conversation's file.
        if let (indexedConv, dateString) = stanzaIndex[stanzaID], indexedConv == conversationID {
            let fileURL = transcriptFileURL(conversationID: conversationID, dateString: dateString)
            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            if let match = messages.first(where: { $0.stanzaID == stanzaID }) {
                return match
            }
        }
        // Slow path: scan all date files
        return try findMessage(in: conversationID) { $0.stanzaID == stanzaID }
    }

    public func findMessage(serverID: String, conversationID: UUID) async throws -> ChatMessage? {
        // Fast path: check server index to read only one file. Verify the indexed
        // conversationID matches for consistency with findMessage(stanzaID:).
        if let (indexedConv, dateString) = serverIndex[serverID], indexedConv == conversationID {
            let fileURL = transcriptFileURL(conversationID: conversationID, dateString: dateString)
            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            if let match = messages.first(where: { $0.serverID == serverID }) {
                return match
            }
        }
        // Slow path: scan all date files
        return try findMessage(in: conversationID) { $0.serverID == serverID }
    }

    public func messageExists(stanzaID: String, conversationID: UUID) async throws -> Bool {
        try await findMessage(stanzaID: stanzaID, conversationID: conversationID) != nil
    }

    public func messageExists(serverID: String, conversationID: UUID) async throws -> Bool {
        try await findMessage(serverID: serverID, conversationID: conversationID) != nil
    }

    // MARK: - Search

    public func searchMessages(
        query: String, conversationID: UUID?,
        before: Date?, after: Date?, limit: Int
    ) async throws -> [ChatMessage] {
        let conversationIDs: [UUID] = if let conversationID {
            [conversationID]
        } else {
            try listConversationIDs()
        }

        var results: [ChatMessage] = []
        for convID in conversationIDs {
            let dateFiles = try listDateFiles(for: convID)
            for (dateString, fileURL) in dateFiles {
                // Skip files outside the date bounds
                if let before, let fileDate = Self.parseDate(dateString), fileDate > before { continue }
                if let after, let fileDate = Self.parseDate(dateString) {
                    // File date is the start of the day; skip if the entire next day is before `after`
                    if let nextDay = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: fileDate),
                       nextDay <= after { continue }
                }
                let messages = try readAndMaterialize(fileURL: fileURL, conversationID: convID)
                let filtered = messages.filter { msg in
                    if let before, msg.timestamp >= before { return false }
                    if let after, msg.timestamp <= after { return false }
                    return msg.body.localizedStandardContains(query)
                }
                results.append(contentsOf: filtered)
                if results.count >= limit { break }
            }
            if results.count >= limit { break }
        }

        results.sort { $0.timestamp > $1.timestamp }
        return Array(results.prefix(limit))
    }

    // MARK: - Stats

    public func messageDateCounts(for conversationID: UUID) async throws -> [(date: Date, count: Int)] {
        let dateFiles = try listDateFiles(for: conversationID)
        return try dateFiles.compactMap { dateString, fileURL in
            guard let date = Self.parseDate(dateString) else { return nil }
            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            return (date, messages.count)
        }
    }

    public func messageCount(for conversationID: UUID) async throws -> Int {
        try await messageDateCounts(for: conversationID).reduce(0) { $0 + $1.count }
    }

    public func messageDateRange(for conversationID: UUID) async throws -> (earliest: Date, latest: Date)? {
        let dateFiles = try listDateFiles(for: conversationID)
        guard !dateFiles.isEmpty else { return nil }

        var earliest: Date?
        var latest: Date?

        // Check the oldest file for earliest
        if let (_, oldestURL) = dateFiles.last {
            let messages = try readAndMaterialize(fileURL: oldestURL, conversationID: conversationID)
            earliest = messages.min(by: { $0.timestamp < $1.timestamp })?.timestamp
        }

        // Check the newest file for latest
        if let (_, newestURL) = dateFiles.first {
            let messages = try readAndMaterialize(fileURL: newestURL, conversationID: conversationID)
            latest = messages.max(by: { $0.timestamp < $1.timestamp })?.timestamp
        }

        guard let earliest, let latest else { return nil }
        return (earliest, latest)
    }

    // MARK: - Lifecycle

    public func deleteTranscripts(for conversationID: UUID) async throws {
        let dir = conversationDirectory(for: conversationID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        // Purge index entries for this conversation
        stanzaIndex = stanzaIndex.filter { $0.value.0 != conversationID }
        serverIndex = serverIndex.filter { $0.value.0 != conversationID }
    }

    public func writeMetadata(_ metadata: TranscriptMetadata, for conversationID: UUID) async throws {
        try ensureDirectoryExists(for: conversationID)
        let metaURL = conversationDirectory(for: conversationID).appendingPathComponent("meta.json")
        let metaEncoder = JSONEncoder()
        metaEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try metaEncoder.encode(metadata)
        try data.write(to: metaURL, options: .atomic)
    }

    // MARK: - Private Helpers

    private func conversationDirectory(for conversationID: UUID) -> URL {
        baseDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    private func transcriptFileURL(conversationID: UUID, dateString: String) -> URL {
        conversationDirectory(for: conversationID).appendingPathComponent("\(dateString).jsonl")
    }

    static func dateString(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: .gmt, from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private static func parseDate(_ dateString: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private func ensureDirectoryExists(for conversationID: UUID) throws {
        let dir = conversationDirectory(for: conversationID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func fileHandle(for fileURL: URL) throws -> FileHandle {
        let path = fileURL.path
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            let posixError = POSIXError(.init(rawValue: errno) ?? .ENOENT)
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: path,
                NSUnderlyingErrorKey: posixError
            ])
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func appendRecord(_ record: TranscriptRecord, to fileURL: URL, conversationID: UUID) throws {
        try ensureDirectoryExists(for: conversationID)
        let handle = try fileHandle(for: fileURL)
        defer { try? handle.close() }
        try writeRecord(record, to: handle)
    }

    private func writeRecord(_ record: TranscriptRecord, to handle: FileHandle) throws {
        var data = try encoder.encode(record)
        data.append(Self.newline)
        handle.write(data)
    }

    /// Scans all date files for a conversation and returns the first message matching the predicate.
    private func findMessage(
        in conversationID: UUID, where predicate: (ChatMessage) -> Bool
    ) throws -> ChatMessage? {
        let dateFiles = try listDateFiles(for: conversationID)
        for (_, fileURL) in dateFiles {
            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            if let match = messages.first(where: predicate) {
                return match
            }
        }
        return nil
    }

    /// Lists date files for a conversation, sorted newest first.
    private func listDateFiles(for conversationID: UUID) throws -> [(dateString: String, url: URL)] {
        let dir = conversationDirectory(for: conversationID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return contents
            .filter { $0.pathExtension == "jsonl" }
            .map { (dateString: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.dateString > $1.dateString } // newest first
    }

    private func listConversationIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: baseDirectory.path) else { return [] }
        let contents = try FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
        return contents.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    // Reads a single JSONL file, parses records, and materializes messages with amendments applied.
    // swiftlint:disable:next cyclomatic_complexity
    private func readAndMaterialize(fileURL: URL, conversationID: UUID) throws -> [ChatMessage] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }

        var messages: [UUID: ChatMessage] = [:]
        var messageOrder: [UUID] = []
        var amendments: [TranscriptAmendment] = []
        var stanzaToID: [String: UUID] = [:]
        var serverToID: [String: UUID] = [:]
        let dateString = fileURL.deletingPathExtension().lastPathComponent

        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines {
            guard !line.isEmpty else { continue }
            do {
                let record = try decoder.decode(TranscriptRecord.self, from: Data(line))
                switch record {
                case .message:
                    if var msg = record.toChatMessage(conversationID: conversationID) {
                        msg.isDelivered = !msg.isOutgoing
                        messages[msg.id] = msg
                        messageOrder.append(msg.id)
                        if let sid = msg.stanzaID {
                            stanzaToID[sid] = msg.id
                            stanzaIndex[sid] = (conversationID, dateString)
                        }
                        if let srvid = msg.serverID {
                            serverToID[srvid] = msg.id
                            serverIndex[srvid] = (conversationID, dateString)
                        }
                    }
                case .amendment:
                    if let amendment = record.toAmendment() {
                        amendments.append(amendment)
                    }
                }
            } catch {
                log.debug("Skipping malformed transcript line: \(error)")
            }
        }

        applyAmendments(amendments, to: &messages, stanzaToID: stanzaToID, serverToID: serverToID)
        return messageOrder.compactMap { messages[$0] }
    }

    /// Applies amendment records to a mutable message dictionary.
    private func applyAmendments(
        _ amendments: [TranscriptAmendment],
        to messages: inout [UUID: ChatMessage],
        stanzaToID: [String: UUID],
        serverToID: [String: UUID]
    ) {
        for amendment in amendments {
            let targetID: UUID? = if let sid = amendment.targetStanzaID {
                stanzaToID[sid]
            } else if let srvid = amendment.targetServerID {
                serverToID[srvid]
            } else {
                nil
            }
            guard let targetID, var msg = messages[targetID] else { continue }

            switch amendment.action {
            case .edit:
                if let body = amendment.body {
                    msg.body = body
                    msg.htmlBody = amendment.htmlBody
                    msg.isEdited = true
                    msg.editedAt = amendment.timestamp
                }
            case .retract:
                msg.isRetracted = true
                msg.retractedAt = amendment.timestamp
                msg.body = ""
                msg.htmlBody = nil
            case .delivery:
                msg.isDelivered = true
            case .error:
                msg.errorText = amendment.errorText
            }

            messages[targetID] = msg
        }
    }
}
