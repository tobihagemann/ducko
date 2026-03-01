import DuckoCore
import SwiftUI

@MainActor @Observable
final class ChatWindowState {
    var conversation: Conversation?
    var messages: [ChatMessage] = []
    var isLoading = false

    private let jidString: String
    private let environment: AppEnvironment

    init(jidString: String, environment: AppEnvironment) {
        self.jidString = jidString
        self.environment = environment
    }

    // MARK: - Public API

    func load() async {
        guard let accountID = environment.accountService.accounts.first?.id else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let conv = try await environment.chatService.openConversation(jidString: jidString, accountID: accountID)
            conversation = conv
            messages = await environment.chatService.loadMessages(for: conv.id)
        } catch {
            // Conversation creation failed — leave state empty
        }
    }

    func refreshMessages() async {
        guard let conversationID = conversation?.id else { return }
        messages = await environment.chatService.loadMessages(for: conversationID)
    }

    func sendMessage(_ body: String) async {
        guard let accountID = environment.accountService.accounts.first?.id else { return }

        do {
            try await environment.chatService.sendMessage(toJIDString: jidString, body: body, accountID: accountID)
        } catch {
            // Send failed — messages stay as-is
        }
    }
}
