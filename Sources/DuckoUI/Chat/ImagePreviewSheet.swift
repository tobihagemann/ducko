import AppKit
import DuckoCore
import SwiftUI

struct ImagePreviewSheet: View {
    let attachment: Attachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(attachment.displayFileName)
                    .font(.headline)

                Spacer()

                Button("Save to Downloads") {
                    saveToDownloads()
                }

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            imageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.05))
        }
        .frame(minWidth: 400, minHeight: 300)
        .accessibilityIdentifier("image-preview")
    }

    @ViewBuilder
    private var imageContent: some View {
        if let imageURL = URL(string: attachment.url) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                case .failure:
                    Label("Failed to load image", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                case .empty:
                    ProgressView()
                @unknown default:
                    EmptyView()
                }
            }
        } else {
            Label("No image URL", systemImage: "photo")
                .foregroundStyle(.secondary)
        }
    }

    private func saveToDownloads() {
        guard let imageURL = URL(string: attachment.url) else { return }

        Task.detached {
            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
                let destination = downloadsURL.appendingPathComponent(attachment.displayFileName)
                try data.write(to: destination)
            } catch {
                // Save failed — silent for now
            }
        }
    }
}
