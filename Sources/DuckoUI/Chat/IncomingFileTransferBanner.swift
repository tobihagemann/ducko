import DuckoCore
import SwiftUI

struct IncomingFileTransferBanner: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let offers = environment.fileTransferService.viewIncomingOffers
        if !offers.isEmpty {
            VStack(spacing: 4) {
                ForEach(offers) { offer in
                    IncomingFileTransferRow(offer: offer)
                }
            }
            .padding(.vertical, 4)
            .background(theme.current.accentColor.resolved(for: colorScheme).opacity(0.1))
            .accessibilityIdentifier("file-transfer-banner")
        }
    }
}

// MARK: - IncomingFileTransferRow

private struct IncomingFileTransferRow: View {
    @Environment(AppEnvironment.self) private var environment
    let offer: FileTransferService.IncomingFileOffer
    @State private var errorMessage: String?

    private var account: Account? {
        environment.accountService.accounts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("File offer: \(offer.fileName)")
                        .font(.callout)
                        .lineLimit(1)

                    Text("\(formattedFileSize) from \(offer.fromJIDString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Accept") {
                    accept()
                }
                .tint(.green)

                Button("Decline") {
                    decline()
                }
                .tint(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: offer.fileSize, countStyle: .file)
    }

    private func accept() {
        guard let accountID = account?.id else { return }
        Task {
            do {
                try await environment.fileTransferService.acceptIncomingTransfer(offer.sid, accountID: accountID)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func decline() {
        guard let accountID = account?.id else { return }
        Task {
            do {
                try await environment.fileTransferService.declineIncomingTransfer(offer.sid, accountID: accountID)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
