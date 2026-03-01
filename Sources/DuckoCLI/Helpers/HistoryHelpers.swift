import DuckoCore
import DuckoXMPP
import Foundation

func parseBeforeDate(_ string: String?) throws -> Date? {
    guard let string else { return nil }
    let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    if let date = try? style.parse(string) {
        return date
    }
    // Try without fractional seconds
    let basicStyle = Date.ISO8601FormatStyle()
    if let date = try? basicStyle.parse(string) {
        return date
    }
    throw CLIError.invalidDate(string)
}

func fetchHistory(
    jid: BareJID, before: Date?, limit: Int,
    environment: AppEnvironment, accountID: UUID
) async throws -> [ChatMessage] {
    try await environment.chatService.loadConversations(for: accountID)
    let conversations = await MainActor.run { environment.chatService.openConversations }
    guard let conversation = conversations.first(where: { $0.jid == jid }) else {
        return []
    }
    return try await environment.chatService.fetchMessageHistory(for: conversation.id, before: before, limit: limit)
}

func printHistory(_ messages: [ChatMessage], formatter: any CLIFormatter) {
    guard !messages.isEmpty else {
        print("No messages found.")
        return
    }
    for message in messages {
        print(formatter.formatMessage(message))
    }
}
