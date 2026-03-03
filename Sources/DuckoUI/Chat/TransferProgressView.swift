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
    let transfer: FileTransferService.ActiveTransfer

    var body: some View {
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
