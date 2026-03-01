import AppKit
import DuckoCore
import SwiftUI

struct MessageContextMenu: View {
    let message: ChatMessage
    let windowState: ChatWindowState

    var body: some View {
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.body, forType: .string)
        }

        Button("Reply") {
            windowState.startReply(to: message)
        }

        if message.isOutgoing, message.stanzaID != nil {
            Button("Edit") {
                windowState.startEdit(of: message)
            }
        }
    }
}
