import DuckoCore
import SwiftUI

struct ContactRow: View {
    @Environment(AppEnvironment.self) private var environment
    let contact: Contact

    private var presence: PresenceService.PresenceStatus? {
        environment.presenceService.contactPresences[contact.jid]
    }

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(contact: contact)

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let statusText = presence?.displayName {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            PresenceIndicator(status: presence)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("contact-row-\(contact.jid)")
    }
}
