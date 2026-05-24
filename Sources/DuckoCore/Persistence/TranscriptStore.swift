import Foundation

public protocol TranscriptStore: Sendable {
    // MARK: - Write

    func appendMessage(_ message: ChatMessage) async throws
    func appendMessages(_ messages: [ChatMessage]) async throws
    func appendAmendment(_ amendment: TranscriptAmendment, conversationID: UUID) async throws

    // MARK: - Read

    func fetchMessages(for conversationID: UUID, before: Date?, limit: Int) async throws -> [ChatMessage]
    func fetchMessages(for conversationID: UUID, on date: Date) async throws -> [ChatMessage]

    // MARK: - Lookup

    /// Locates a message by locally-assigned UUID. Unlike `findMessage(stanzaID:)`,
    /// the UUID is unique per persisted message and survives MAM-imported
    /// `ducko-N` counter duplicates from prior sessions.
    func findMessage(id: UUID, conversationID: UUID) async throws -> ChatMessage?
    func findMessage(stanzaID: String, conversationID: UUID) async throws -> ChatMessage?
    // periphery:ignore - used by MUC moderation (XEP-0425) serverID lookup path
    func findMessage(serverID: String, conversationID: UUID) async throws -> ChatMessage?
    func messageExists(stanzaID: String, conversationID: UUID) async throws -> Bool
    func messageExists(serverID: String, conversationID: UUID) async throws -> Bool
    /// XEP-0359 stanza-id values are unique only *per sender*, so callers that
    /// dedup inbound stanzas must scope the lookup by `fromJID`. Otherwise an
    /// old archived outgoing message from this account with a colliding
    /// `stanzaID` (e.g. CLI counter resets across processes) would mark a
    /// fresh incoming message as duplicate and silently drop it.
    func messageExists(stanzaID: String, fromJID: String, conversationID: UUID) async throws -> Bool

    // MARK: - Search

    func searchMessages(query: String, conversationID: UUID?, before: Date?, after: Date?, limit: Int) async throws -> [ChatMessage]

    // MARK: - Stats

    func messageCount(for conversationID: UUID) async throws -> Int
    func messageDateCounts(for conversationID: UUID) async throws -> [(date: Date, count: Int)]
    func messageDateRange(for conversationID: UUID) async throws -> (earliest: Date, latest: Date)?

    // MARK: - Lifecycle

    func deleteTranscripts(for conversationID: UUID) async throws
    func writeMetadata(_ metadata: TranscriptMetadata, for conversationID: UUID) async throws
}

// MARK: - Default Implementations

public extension TranscriptStore {
    func appendMessages(_ messages: [ChatMessage]) async throws {
        for message in messages {
            try await appendMessage(message)
        }
    }
}
