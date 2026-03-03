import AppKit
import DuckoCore
import SwiftUI

struct LinkPreviewCard: View {
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let preview: LinkPreview

    var body: some View {
        Button {
            if let url = URL(string: preview.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                if let imageURLString = preview.imageURL, let imageURL = URL(string: imageURLString) {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .empty, .failure:
                            Color.clear
                        @unknown default:
                            Color.clear
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let title = preview.title {
                        Text(title)
                            .font(.callout)
                            .bold()
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }

                    if let description = preview.descriptionText {
                        Text(description)
                            .font(.caption)
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }

                    if let siteName = preview.siteName {
                        Text(siteName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()
            }
            .padding(8)
            .background(theme.current.backgroundColor.resolved(for: colorScheme), in: .rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.current.separatorColor.resolved(for: colorScheme), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("link-preview")
    }
}
