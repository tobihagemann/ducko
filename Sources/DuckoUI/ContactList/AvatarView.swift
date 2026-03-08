import AppKit
import DuckoCore
import SwiftUI

struct AvatarView: View {
    @Environment(ThemeEngine.self) private var theme
    let contact: Contact
    var size: CGFloat = 32
    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(avatarClipShape)
            } else {
                initialsView
            }
        }
        .task(id: contact.avatarData) {
            nsImage = contact.avatarData.flatMap(NSImage.init(data:))
        }
    }

    private var initialsView: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [.blue, .blue.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: avatarClipShape
            )
    }

    private var avatarClipShape: AnyShape {
        theme.current.avatarShape.clipShape(size: size)
    }

    private var initials: String {
        let name = contact.displayName
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}
