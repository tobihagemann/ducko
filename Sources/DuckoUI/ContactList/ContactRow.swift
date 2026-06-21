import DuckoCore
import SwiftUI

struct ContactRow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    let contact: Contact
    /// When true, render a zero-decode avatar placeholder of the same
    /// `avatarSize × avatarSize` frame instead of the real `AvatarView`. Used by
    /// the off-screen row-measuring layer so measuring every off-screen row does
    /// not trigger an uncached ImageIO decode per contact — the avatar's height
    /// contribution is exactly `avatarSize` regardless of image content.
    var forMeasurement = false

    private var presence: PresenceService.PresenceStatus? {
        environment.presenceService.presence(for: contact.jid, accountID: contact.accountID)
    }

    private var display: ContactPresenceDisplay {
        ContactPresenceDisplay.resolve(for: contact, accountID: contact.accountID, presenceService: environment.presenceService)
    }

    private var statusMessage: String? {
        environment.presenceService.statusMessage(for: contact.jid, accountID: contact.accountID)
    }

    /// The disambiguation label shown when this contact's JID is on more than one account; nil otherwise.
    private var accountLabel: String? {
        AccountIndicator.label(
            for: contact.accountID, bareJID: contact.jid.description,
            accountService: environment.accountService, rosterService: environment.rosterService
        )
    }

    /// JID-only when unique; account-qualified when the JID is duplicated so the two same-JID rows
    /// are individually addressable by automation. Single-account users keep the plain `{jid}` id.
    private var accessibilityKey: String {
        AccountIndicator.qualified(contact.jid.description, accountID: contact.accountID, qualify: accountLabel != nil, accountService: environment.accountService)
    }

    var body: some View {
        HStack(spacing: 8) {
            if theme.current.showPresenceIndicators {
                PresenceIndicator(display: display)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(contact.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if let accountLabel {
                        AccountLabelText(label: accountLabel)
                    }
                }

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
                if forMeasurement {
                    Color.clear
                        .frame(width: theme.current.avatarSize, height: theme.current.avatarSize)
                } else {
                    AvatarView(contact: contact, size: theme.current.avatarSize)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("contact-row-\(accessibilityKey)")
    }
}
