import DuckoCore
import Foundation

public actor MockTranscriptStore: TranscriptStore {
    public var messages: [ChatMessage] = []
    public var amendments: [(amendment: TranscriptAmendment, conversationID: UUID)] = []

    public init() {}

    public func addMessage(_ message: ChatMessage) {
        messages.append(message)
    }

    // MARK: - Write

    public func appendMessage(_ message: ChatMessage) async throws {
        messages.append(message)
    }

    public func appendMessages(_ messages: [ChatMessage]) async throws {
        self.messages.append(contentsOf: messages)
    }

    public func appendAmendment(_ amendment: TranscriptAmendment, conversationID: UUID) async throws {
        amendments.append((amendment, conversationID))
    }

    // MARK: - Read

    public func fetchMessages(for conversationID: UUID, before: Date?, limit: Int) async throws -> [ChatMessage] {
        var filtered = messages.filter { $0.conversationID == conversationID }
        if let before {
            filtered = filtered.filter { $0.timestamp < before }
        }
        var result = Array(filtered.sorted(by: { $0.timestamp > $1.timestamp }).prefix(limit))
        result = applyAmendments(to: result)
        return result
    }

    public func fetchMessages(for conversationID: UUID, on date: Date) async throws -> [ChatMessage] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var filtered = messages.filter {
            $0.conversationID == conversationID && calendar.isDate($0.timestamp, inSameDayAs: date)
        }
        filtered = applyAmendments(to: filtered)
        return filtered.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Lookup

    public func findMessage(stanzaID: String, conversationID: UUID) async throws -> ChatMessage? {
        let match = messages.first { $0.stanzaID == stanzaID && $0.conversationID == conversationID }
        guard var message = match else { return nil }
        message = applyAmendments(to: [message]).first ?? message
        return message
    }

    // periphery:ignore - protocol conformance for MUC moderation serverID lookup
    public func findMessage(serverID: String, conversationID: UUID) async throws -> ChatMessage? {
        let match = messages.first { $0.serverID == serverID && $0.conversationID == conversationID }
        guard var message = match else { return nil }
        message = applyAmendments(to: [message]).first ?? message
        return message
    }

    public func messageExists(stanzaID: String, conversationID: UUID) async throws -> Bool {
        messages.contains { $0.stanzaID == stanzaID && $0.conversationID == conversationID }
    }

    public func messageExists(serverID: String, conversationID: UUID) async throws -> Bool {
        messages.contains { $0.serverID == serverID && $0.conversationID == conversationID }
    }

    public func messageExists(stanzaID: String, fromJID: String, conversationID: UUID) async throws -> Bool {
        // Match FileTranscriptStore: outgoing rows store `fromJID` as the
        // recipient, so an unfiltered match would shadow fresh inbound stanzas.
        messages.contains {
            !$0.isOutgoing
                && $0.stanzaID == stanzaID
                && $0.fromJID == fromJID
                && $0.conversationID == conversationID
        }
    }

    // MARK: - Search

    public func searchMessages(query: String, conversationID: UUID?, before: Date?, after: Date?, limit: Int) async throws -> [ChatMessage] {
        var results = applyAmendments(to: messages)
        results = results.filter { $0.body.localizedStandardContains(query) }
        if let conversationID {
            results = results.filter { $0.conversationID == conversationID }
        }
        if let before {
            results = results.filter { $0.timestamp < before }
        }
        if let after {
            results = results.filter { $0.timestamp > after }
        }
        return Array(results.sorted(by: { $0.timestamp > $1.timestamp }).prefix(limit))
    }

    // MARK: - Stats

    public func messageDateCounts(for conversationID: UUID) async throws -> [(date: Date, count: Int)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var counts: [Date: Int] = [:]
        for message in messages where message.conversationID == conversationID {
            let day = calendar.startOfDay(for: message.timestamp)
            counts[day, default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.date > $1.date }
    }

    public func messageCount(for conversationID: UUID) async throws -> Int {
        messages.count(where: { $0.conversationID == conversationID })
    }

    public func messageDateRange(for conversationID: UUID) async throws -> (earliest: Date, latest: Date)? {
        let convMessages = messages.filter { $0.conversationID == conversationID }
        guard let earliest = convMessages.min(by: { $0.timestamp < $1.timestamp })?.timestamp,
              let latest = convMessages.max(by: { $0.timestamp < $1.timestamp })?.timestamp else {
            return nil
        }
        return (earliest, latest)
    }

    // MARK: - Lifecycle

    public func deleteTranscripts(for conversationID: UUID) async throws {
        messages.removeAll { $0.conversationID == conversationID }
        // Conversation-targeted amendments are kept (orphaned but harmless) for mock simplicity.
    }

    public func writeMetadata(_ metadata: TranscriptMetadata, for conversationID: UUID) async throws {}

    // MARK: - Amendment Application

    private func applyAmendments(to messages: [ChatMessage]) -> [ChatMessage] {
        var result = messages
        for (amendment, conversationID) in amendments {
            for index in result.indices where result[index].conversationID == conversationID {
                let matchesStanza = amendment.targetStanzaID != nil && result[index].stanzaID == amendment.targetStanzaID
                let matchesServer = amendment.targetServerID != nil && result[index].serverID == amendment.targetServerID
                guard matchesStanza || matchesServer else { continue }

                switch amendment.action {
                case .edit:
                    if let body = amendment.body {
                        result[index].body = body
                    }
                    if let htmlBody = amendment.htmlBody {
                        result[index].htmlBody = htmlBody
                    }
                    result[index].isEdited = true
                    result[index].editedAt = amendment.timestamp
                case .retract:
                    result[index].isRetracted = true
                    result[index].retractedAt = amendment.timestamp
                    result[index].body = ""
                    result[index].htmlBody = nil
                case .delivery:
                    result[index].isDelivered = true
                case .error:
                    if let errorText = amendment.errorText {
                        result[index].errorText = errorText
                    }
                }
            }
        }
        return result
    }
}
