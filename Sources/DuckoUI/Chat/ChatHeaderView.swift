import DuckoCore
import SwiftUI

struct ChatHeaderView: View {
    @Environment(AppEnvironment.self) private var environment
    let conversation: Conversation

    private var connectionState: AccountService.ConnectionState {
        environment.accountService.connectionStates[conversation.accountID] ?? .disconnected
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayName ?? conversation.jid.description)
                    .font(.headline)

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        switch connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .gray
        case .error: .red
        }
    }

    private var statusText: String {
        switch connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Disconnected"
        case let .error(message): message
        }
    }
}
