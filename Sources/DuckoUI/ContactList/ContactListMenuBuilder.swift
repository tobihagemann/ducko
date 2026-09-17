import AppKit
import DuckoCore
import SwiftUI

@MainActor
final class ContactListMenuBuilder {
    private let openChat: OpenChatAction
    private let openWindow: OpenWindowAction?
    private let transcriptScope: TranscriptScope?
    private let presentSheet: (ContactListRowSheet) -> Void
    private weak var target: AnyObject?
    private let action: Selector

    init(
        openChat: OpenChatAction, openWindow: OpenWindowAction?, transcriptScope: TranscriptScope?,
        presentSheet: @escaping (ContactListRowSheet) -> Void, target: AnyObject, action: Selector
    ) {
        self.openChat = openChat
        self.openWindow = openWindow
        self.transcriptScope = transcriptScope
        self.presentSheet = presentSheet
        self.target = target
        self.action = action
    }

    func menu(for row: ContactListRow, environment: AppEnvironment) -> NSMenu? {
        switch row {
        case .header: nil
        case let .contact(_, contact): contactMenu(for: contact, environment: environment)
        case let .room(room): roomMenu(for: room, environment: environment)
        }
    }

    private func contactMenu(for contact: Contact, environment: AppEnvironment) -> NSMenu {
        let conversation = environment.chatService.openConversations.first {
            $0.jid == contact.jid && $0.accountID == contact.accountID
        }
        let menu = NSMenu()
        menu.addItem(item("Start Chat") {
            self.openChat(contact.jid.description, accountID: contact.accountID)
        })
        menu.addItem(item("Get Info", identifier: "contact-context-get-info") {
            self.openWindow?(id: "contact-info", value: ContactInfoRef(accountID: contact.accountID, jid: contact.jid.description))
        })
        menu.addItem(item("History", identifier: "contact-context-history") {
            let ref = conversation.map { ConversationRef(conversation: $0) }
                ?? ConversationRef(accountID: contact.accountID, jid: contact.jid.description, type: .chat)
            self.transcriptScope?.request(ref)
            self.openWindow?(id: "transcripts")
        })
        menu.addItem(.separator())
        if let conversation {
            for menuItem in pinMuteItems(for: conversation, accountID: contact.accountID, environment: environment) {
                menu.addItem(menuItem)
            }
            menu.addItem(.separator())
        }
        menu.addItem(item("Rename…") {
            self.presentSheet(.rename(contact))
        })
        menu.addItem(item("Send Directed Presence", identifier: "send-directed-presence-menu-item") {
            Task { try? await environment.presenceService.sendDirectedPresence(to: contact.jid.description, accountID: contact.accountID) }
        })
        menu.addItem(.separator())
        menu.addItem(item(contact.isBlocked ? "Unblock" : "Block") {
            Task {
                if contact.isBlocked {
                    try? await environment.rosterService.unblockContact(jidString: contact.jid.description, accountID: contact.accountID)
                } else {
                    try? await environment.rosterService.blockContact(jidString: contact.jid.description, accountID: contact.accountID)
                }
            }
        })
        menu.addItem(item("Remove Contact") {
            Task { try? await environment.rosterService.removeContact(contact, accountID: contact.accountID) }
        })
        return menu
    }

    private func roomMenu(for conversation: Conversation, environment: AppEnvironment) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open Chat") {
            self.openChat(conversation.jid.description, accountID: conversation.accountID)
        })
        guard let accountID = conversation.accountID else { return menu }
        menu.addItem(.separator())
        for menuItem in pinMuteItems(for: conversation, accountID: accountID, environment: environment) {
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        menu.addItem(item("Invite User…") {
            self.presentSheet(.invite(conversation))
        })
        if canManageRoom(conversation, accountID: accountID, environment: environment) {
            menu.addItem(.separator())
            menu.addItem(item("Room Settings…", identifier: "room-settings-menu-item") {
                self.presentSheet(.roomSettings(conversation))
            })
        }
        menu.addItem(.separator())
        menu.addItem(item("Leave Room") {
            Task { try? await environment.chatService.leaveRoom(jidString: conversation.jid.description, accountID: accountID) }
        })
        return menu
    }

    /// The Pin/Unpin + Mute/Unmute pair shared by the contact and room menus.
    private func pinMuteItems(for conversation: Conversation, accountID: UUID, environment: AppEnvironment) -> [NSMenuItem] {
        [
            item(conversation.isPinned ? "Unpin" : "Pin") {
                Task { try? await environment.chatService.togglePin(conversationID: conversation.id, accountID: accountID) }
            },
            item(conversation.isMuted ? "Unmute" : "Mute") {
                Task { try? await environment.chatService.toggleMute(conversationID: conversation.id, accountID: accountID) }
            }
        ]
    }

    private func canManageRoom(_ conversation: Conversation, accountID: UUID, environment: AppEnvironment) -> Bool {
        guard let nickname = conversation.roomNickname else { return false }
        let participants = environment.chatService.participants(forRoomJIDString: conversation.jid.description, accountID: accountID)
        return participants.first { $0.nickname == nickname }?.affiliation == .owner
    }

    /// One menu item whose action runs `run` via the single `@objc`
    /// trampoline (closures aren't valid `NSMenuItem` actions; this is the
    /// minimal target/action footprint).
    private func item(_ title: String, identifier: String? = nil, run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = target
        menuItem.representedObject = MenuCommand(run)
        if let identifier {
            menuItem.setAccessibilityIdentifier(identifier)
        }
        return menuItem
    }
}
