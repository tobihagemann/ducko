import DuckoCore
import Foundation

extension AppEnvironment {
    /// Applies a presence to every enabled account, connecting or disconnecting accounts as the status requires.
    func applyGlobalStatus(_ status: PresenceService.PresenceStatus, message: String?) {
        Task {
            await presenceService.applyGlobalPresence(status, message: message) { id in
                try await self.accountService.connect(accountID: id)
            } disconnect: { id in
                await self.accountService.disconnect(accountID: id)
            }
        }
    }

    /// Applies a presence to one account without touching the global status, connecting or disconnecting it as the
    /// status requires.
    func applyAccountStatus(_ status: PresenceService.PresenceStatus, accountID: UUID) {
        Task {
            await presenceService.applyAccountPresence(status, message: nil, accountID: accountID) { id in
                try await self.accountService.connect(accountID: id)
            } disconnect: { id in
                await self.accountService.disconnect(accountID: id)
            }
        }
    }
}
