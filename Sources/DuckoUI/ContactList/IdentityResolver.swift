import DuckoCore
import Foundation

/// Resolves the account whose avatar, name, and status the Contacts "me" header shows. Every status surface resolves
/// through it, so they agree on the current status.
enum IdentityResolver {
    /// Resolution order: the persisted pick if still enabled, then the held identity if still enabled and connected,
    /// then the first connected account, then the first enabled one. The pick wins even while disconnected, so an
    /// account taken offline stays in the header reading Offline. Without an enabled pick, the held step keeps the
    /// header from bouncing while accounts finish their handshakes in different orders.
    static func resolve(
        pickedID: UUID?,
        heldID: UUID?,
        accounts: [Account],
        connectionStates: [UUID: AccountService.ConnectionState]
    ) -> Account? {
        func isConnected(_ id: UUID) -> Bool {
            if case .connected? = connectionStates[id] { return true }
            return false
        }
        if let pickedID, let picked = accounts.first(where: { $0.id == pickedID && $0.isEnabled }) {
            return picked
        }
        if let heldID, let held = accounts.first(where: { $0.id == heldID && $0.isEnabled }), isConnected(heldID) {
            return held
        }
        return accounts.first { isConnected($0.id) } ?? accounts.first { $0.isEnabled }
    }
}

extension AppEnvironment {
    /// The header's identity account, resolved from the shared preferences so every caller sees the same account.
    func identityAccount(preferences: StatusBarPreferences) -> Account? {
        IdentityResolver.resolve(
            pickedID: preferences.identityAccountID,
            heldID: preferences.heldIdentityAccountID,
            accounts: accountService.accounts,
            connectionStates: accountService.connectionStates
        )
    }

    /// The name you go by on an account.
    func ownName(of account: Account?) -> String {
        account?.displayName
            ?? account.flatMap { profileService.ownProfile(for: $0.id)?.nickname }
            ?? account?.jid.localPart
            ?? account?.jid.domainPart
            ?? "Me"
    }

    /// What your `/me` lines in a conversation call you: your nickname in a room or in a private chat within one,
    /// otherwise the name you go by on the account.
    func ownName(in conversation: Conversation) -> String {
        let roomNickname = if conversation.occupantNickname == nil {
            conversation.roomNickname
        } else {
            // A private chat's own record names only the occupant, so your nickname comes from the room's.
            chatService.openConversations.first {
                $0.type == .groupchat && $0.jid == conversation.jid && $0.accountID == conversation.accountID
            }?.roomNickname
        }
        return roomNickname ?? ownName(of: accountService.accounts.first { $0.id == conversation.accountID })
    }
}
