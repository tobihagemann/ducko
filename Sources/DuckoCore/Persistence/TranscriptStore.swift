import Foundation

public protocol TranscriptStore: Sendable {
    // MARK: - Write

    func appendMessage(_ message: ChatMessage) async throws
    func appendMessages(_ messages: [ChatMessage]) async throws
    func appendAmendment(_ amendment: TranscriptAmendment) async throws

    // MARK: - Read

    func fetchMessages(for conversationID: UUID, before: Date?, limit: Int) async throws -> [ChatMessage]

    // MARK: - Lookup

    func findMessage(stanzaID: String, conversationID: UUID) async throws -> ChatMessage?
    // periphery:ignore - used by MUC moderation (XEP-0425) serverID lookup path
    func findMessage(serverID: String, conversationID: UUID) async throws -> ChatMessage?
    func messageExists(stanzaID: String, conversationID: UUID) async throws -> Bool
    func messageExists(serverID: String, conversationID: UUID) async throws -> Bool

    // MARK: - Search

    func searchMessages(query: String, conversationID: UUID?, before: Date?, after: Date?, limit: Int) async throws -> [ChatMessage]

    // MARK: - Stats

    func messageCount(for conversationID: UUID) async throws -> Int
    func messageDateRange(for conversationID: UUID) async throws -> (earliest: Date, latest: Date)?

    // MARK: - Lifecycle

    // periphery:ignore - infrastructure for account/conversation deletion cascade
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
