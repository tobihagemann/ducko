import DuckoCore
import Foundation

/// Resolves the account whose avatar, name, and status the Contacts "me" header shows. Every status surface resolves
/// through it, so they agree on the current status.
enum IdentityResolver {
    /// Resolution order: the persisted pick if connected, then the held identity if still enabled and connected, then
    /// the first connected account, then the first enabled one. The held step keeps the header from bouncing while a
    /// pick is still connecting or accounts finish their handshakes in different orders.
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
        if let pickedID, let picked = accounts.first(where: { $0.id == pickedID }), isConnected(pickedID) {
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
}
