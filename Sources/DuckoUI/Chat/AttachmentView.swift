import AppKit
import DuckoCore
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentView: View {
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let attachment: Attachment
    let isOutgoing: Bool
    @State private var showPreview = false

    var body: some View {
        if attachment.isImage {
            imageAttachment
        } else {
            fileAttachment
        }
    }

    private var imageAttachment: some View {
        Group {
            if let imageURL = URL(string: attachment.url) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure:
                        imagePlaceholder(systemName: "photo.badge.exclamationmark")
                    case .empty:
                        imagePlaceholder(systemName: "photo")
                            .overlay { ProgressView() }
                    @unknown default:
                        imagePlaceholder(systemName: "photo")
                    }
                }
            } else {
                imagePlaceholder(systemName: "photo")
            }
        }
        .frame(maxWidth: 240, maxHeight: 240)
        .clipShape(.rect(cornerRadius: 8))
        .onTapGesture { showPreview = true }
        .sheet(isPresented: $showPreview) {
            ImagePreviewSheet(attachment: attachment)
        }
        .accessibilityIdentifier("attachment-view")
    }

    private func imagePlaceholder(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .frame(width: 120, height: 80)
    }

    private var fileAttachment: some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon)
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayFileName)
                    .font(.callout)
                    .lineLimit(1)

                if let oobDescription = attachment.oobDescription, !oobDescription.isEmpty {
                    Text(oobDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let size = attachment.formattedFileSize {
                    Text(size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let fileURL = URL(string: attachment.url) {
                Button {
                    NSWorkspace.shared.open(fileURL)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            isOutgoing
                ? theme.current.outgoingBubbleColor.resolved(for: colorScheme).opacity(0.3)
                : theme.current.backgroundColor.resolved(for: colorScheme),
            in: .rect(cornerRadius: 8)
        )
        .accessibilityIdentifier("attachment-view")
    }

    private var fileIcon: String {
        guard let mimeType = attachment.mimeType,
              let utType = UTType(mimeType: mimeType) else {
            return "doc"
        }

        if utType.conforms(to: .pdf) { return "doc.richtext" }
        if utType.conforms(to: .audio) { return "music.note" }
        if utType.conforms(to: .movie) { return "film" }
        if utType.conforms(to: .archive) { return "doc.zipper" }
        if utType.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}
