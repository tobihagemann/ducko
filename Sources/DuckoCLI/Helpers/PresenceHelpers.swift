import DuckoCore
import Foundation

/// Every caller connects its account before invoking this, so the multi-account reconnect branch never
/// fires; `accountID` seeds the reconnect fallback for symmetry.
@MainActor
func applyPresence(
    _ presenceStatus: PresenceService.PresenceStatus,
    message: String?,
    environment: AppEnvironment,
    accountID: UUID
) async {
    await environment.presenceService.applyGlobalPresence(
        presenceStatus,
        message: message,
        identityAccountID: accountID
    ) { id in
        try await environment.accountService.connect(accountID: id)
    } disconnect: { id in
        await environment.accountService.disconnect(accountID: id)
    }
}
