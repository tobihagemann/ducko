import DuckoCore
import Foundation

func fetchAndFormatProfile(
    environment: AppEnvironment, accountID: UUID, formatter: any CLIFormatter
) async -> String {
    await environment.profileService.fetchOwnProfile(accountID: accountID)
    let profile = await MainActor.run { environment.profileService.ownProfile(for: accountID) }
    if let profile {
        return formatter.formatProfile(profile)
    }
    return formatter.formatProfile(ProfileInfo())
}
