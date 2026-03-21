import DuckoCore
import SwiftUI

struct TransferProgressView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let transfers = environment.fileTransferService.activeTransfers.filter { isActive($0.state) }
        if !transfers.isEmpty {
            VStack(spacing: 4) {
                ForEach(transfers) { transfer in
                    TransferProgressRow(transfer: transfer)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityIdentifier("transfer-progress")
        }
    }

    private func isActive(_ state: FileTransferService.TransferState) -> Bool {
        switch state {
        case .requestingSlot, .uploading, .negotiating, .connectingTransport,
             .transferring, .awaitingAcceptance:
            true
        case .completed, .failed, .completedTransfer:
            false
        }
    }
}

// MARK: - TransferProgressRow

private struct TransferProgressRow: View {
    @Environment(AppEnvironment.self) private var environment
    let transfer: FileTransferService.ActiveTransfer
    @State private var showFileImporter = false
    @State private var errorMessage: String?

    private var account: Account? {
        environment.accountService.accounts.first
    }

    private var canAddFile: Bool {
        transfer.isSessionLevel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.fileName)
                        .font(.callout)
                        .lineLimit(1)

                    Text(stateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let progress = transferProgress {
                    ProgressView(value: progress)
                        .frame(width: 100)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(formattedFileSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if canAddFile {
                    Button {
                        showFileImporter = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .help("Add file to session")
                    .accessibilityIdentifier("add-file-to-session-button")
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelected(result)
        }
    }

    private func handleFileSelected(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first, let sid = transfer.sid, let accountID = account?.id else { return }

            // Copy to temp so the security-scoped bookmark isn't needed when the peer accepts
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Cannot access file"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let tempDir = FileManager.default.temporaryDirectory
            let dest = tempDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else {
                errorMessage = "Failed to copy file"
                return
            }

            Task {
                do {
                    try await environment.fileTransferService.addFileToSession(sid: sid, url: dest, accountID: accountID)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    private var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: transfer.fileSize, countStyle: .file)
    }

    private var stateLabel: String {
        switch transfer.state {
        case .requestingSlot:
            "Requesting upload slot..."
        case let .uploading(progress):
            "Uploading \(Int(progress * 100))%"
        case .negotiating:
            "Negotiating..."
        case .connectingTransport:
            "Connecting..."
        case let .transferring(progress):
            "Transferring \(Int(progress * 100))%"
        case .awaitingAcceptance:
            "Awaiting acceptance..."
        case .completed, .completedTransfer:
            "Completed"
        case let .failed(reason):
            "Failed: \(reason)"
        }
    }

    private var transferProgress: Double? {
        switch transfer.state {
        case let .uploading(progress):
            progress
        case let .transferring(progress):
            progress
        case .requestingSlot, .negotiating, .connectingTransport, .awaitingAcceptance,
             .completed, .completedTransfer, .failed:
            nil
        }
    }
}
