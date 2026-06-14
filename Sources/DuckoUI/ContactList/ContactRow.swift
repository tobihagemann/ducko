import DuckoCore
import SwiftUI

struct ContactRow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    let contact: Contact

    private var presence: PresenceService.PresenceStatus? {
        environment.presenceService.contactPresences[contact.jid]
    }

    private var display: ContactPresenceDisplay {
        ContactPresenceDisplay.resolve(for: contact, presenceService: environment.presenceService)
    }

    private var statusMessage: String? {
        environment.presenceService.statusMessage(for: contact.jid)
    }

    var body: some View {
        HStack(spacing: 8) {
            if theme.current.showPresenceIndicators {
                PresenceIndicator(display: display)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if theme.current.showStatusMessages, let statusText = statusMessage ?? presence?.displayName {
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

            if theme.current.showAvatars {
                AvatarView(contact: contact, size: theme.current.avatarSize)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("contact-row-\(contact.jid)")
    }
}
