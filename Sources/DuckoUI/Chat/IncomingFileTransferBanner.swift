import DuckoCore
import SwiftUI
import UniformTypeIdentifiers

struct IncomingFileTransferBanner: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let offers = environment.fileTransferService.viewIncomingOffers
        let requests = environment.fileTransferService.viewIncomingRequests
        if !offers.isEmpty || !requests.isEmpty {
            VStack(spacing: 4) {
                ForEach(offers) { offer in
                    IncomingFileTransferRow(offer: offer)
                }
                ForEach(requests) { request in
                    IncomingFileRequestRow(request: request)
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
                .accessibilityIdentifier("accept-file-transfer-button")

                Button("Decline") {
                    decline()
                }
                .tint(.red)
                .accessibilityIdentifier("decline-file-transfer-button")
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

// MARK: - IncomingFileRequestRow

private struct IncomingFileRequestRow: View {
    @Environment(AppEnvironment.self) private var environment
    let request: FileTransferService.IncomingFileRequest
    @State private var errorMessage: String?
    @State private var showFileImporter = false

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
                    Text("File request: \(request.fileName)")
                        .font(.callout)
                        .lineLimit(1)

                    Text("\(formattedFileSize) from \(request.fromJIDString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Fulfill") {
                    showFileImporter = true
                }
                .tint(.green)
                .accessibilityIdentifier("fulfill-file-request-button")

                Button("Decline") {
                    decline()
                }
                .tint(.red)
                .accessibilityIdentifier("decline-file-request-button")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelected(result)
        }
    }

    private var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: request.fileSize, countStyle: .file)
    }

    private func handleFileSelected(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            fulfill(fileURL: url)
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    private func fulfill(fileURL: URL) {
        guard let accountID = account?.id else { return }
        Task {
            guard fileURL.startAccessingSecurityScopedResource() else { return }
            let fileData: [UInt8]
            do {
                fileData = try Array(Data(contentsOf: fileURL))
            } catch {
                fileURL.stopAccessingSecurityScopedResource()
                errorMessage = error.localizedDescription
                return
            }
            fileURL.stopAccessingSecurityScopedResource()
            do {
                try await environment.fileTransferService.fulfillFileRequest(request.sid, fileData: fileData, accountID: accountID)
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
                try await environment.fileTransferService.declineFileRequest(request.sid, accountID: accountID)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
