import AppKit
import DuckoCore
import SwiftUI

struct MessageContextMenu: View {
    let message: ChatMessage
    let windowState: ChatWindowState

    /// Buttons inside `.contextMenu { }` carry no `.accessibilityIdentifier`:
    /// SwiftUI does not reliably propagate the modifier to the bridged
    /// `kAXMenuItemRole` element on macOS 26, so identifier-based AX lookups
    /// can land on a sibling. UI integration tests select context-menu items
    /// by title via `AppAccessor.contextMenuItem(title:)`, which matches
    /// `kAXTitleAttribute` directly.
    var body: some View {
        if !message.isRetracted {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.body, forType: .string)
            }

            Button("Reply") {
                windowState.startReply(to: message)
            }
        }

        if message.isOutgoing, !message.isRetracted, message.stanzaID != nil {
            Button("Edit") {
                windowState.startEdit(of: message)
            }

            Button("Retract") {
                Task {
                    await windowState.retractMessage(message)
                }
            }
        }

        if !message.isOutgoing, !message.isRetracted, message.serverID != nil,
           windowState.isGroupchat, windowState.myRoomRole == .moderator {
            Button("Remove Message") {
                Task {
                    await windowState.moderateMessage(message, reason: nil)
                }
            }
        }
    }
}
