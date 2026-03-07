import DuckoCore
import SwiftUI

struct ContactRow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    let contact: Contact

    private var presence: PresenceService.PresenceStatus? {
        environment.presenceService.contactPresences[contact.jid]
    }

    var body: some View {
        HStack(spacing: 8) {
            if theme.current.showAvatars {
                AvatarView(contact: contact, size: theme.current.avatarSize)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if theme.current.showStatusMessages, let statusText = presence?.displayName {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if contact.isPendingSubscription {
                    Text("Pending approval")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if presence == nil, let lastSeen = contact.lastSeen {
                    Text("Last seen \(lastSeen, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if theme.current.showPresenceIndicators {
                PresenceIndicator(status: presence, isPendingSubscription: contact.isPendingSubscription)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("contact-row-\(contact.jid)")
    }
}
