import AppKit
import DuckoCore
import SwiftUI

struct PendingAttachmentBar: View {
    let windowState: ChatWindowState

    var body: some View {
        if !windowState.pendingAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(windowState.pendingAttachments) { attachment in
                        PendingAttachmentCard(attachment: attachment) {
                            windowState.removeAttachment(id: attachment.id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(Color(.windowBackgroundColor))
            .accessibilityIdentifier("pending-attachments")
        }
    }
}

// MARK: - PendingAttachmentCard

private struct PendingAttachmentCard: View {
    let attachment: DraftAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                if attachment.isImage, let nsImage = NSImage(contentsOf: attachment.url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 6))
                } else {
                    Image(systemName: "doc")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                }

                Text(attachment.fileName)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 64)
            }
            .padding(4)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }
}
