import DuckoCore
import Foundation

extension AppEnvironment {
    /// Applies a presence to every account, connecting or disconnecting accounts as the status requires.
    /// `identityAccountID` is the account to connect when going online finds no connect-on-launch account.
    func applyGlobalStatus(_ status: PresenceService.PresenceStatus, message: String?, identityAccountID: UUID?) {
        Task {
            await presenceService.applyGlobalPresence(status, message: message, identityAccountID: identityAccountID) { id in
                try await self.accountService.connect(accountID: id)
            } disconnect: { id in
                await self.accountService.disconnect(accountID: id)
            }
        }
    }
}
