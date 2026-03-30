import DuckoCore
import SwiftUI

/// Shared progress indicator for Adium log import. Shows a determinate progress bar with file and message counts.
struct AdiumImportProgressView: View {
    let progress: AdiumImportService.ImportProgress

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(progress.completedFiles), total: Double(max(progress.totalFiles, 1)))

            Text("\(progress.completedFiles) / \(progress.totalFiles) files")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(progress.importedMessages) messages imported")
                .font(.caption)
        }
    }
}

/// Shared completion view for Adium import. Shows checkmark, stats, and optional account results.
/// Does NOT include action buttons — parents add their own "Done" button.
struct AdiumImportCompletionView: View {
    struct AccountResult: Identifiable {
        let id: String
        let jid: String
        let success: Bool
        let error: String?
    }

    let result: AdiumImportService.ImportProgress?
    var accountResults: [AccountResult] = []

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)

            Text("Import Complete")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                if !accountResults.isEmpty {
                    let succeeded = accountResults.filter(\.success).count
                    Text("Accounts connected: \(succeeded)/\(accountResults.count)")
                }
                if let result {
                    Text("Messages imported: \(result.importedMessages)")
                    Text("Duplicates skipped: \(result.skippedDuplicates)")
                    if !result.errors.isEmpty {
                        Text("Errors: \(result.errors.count)")
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.callout)

            let failedAccounts = accountResults.filter { !$0.success }
            if !failedAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(failedAccounts) { account in
                        Text("\(account.jid): \(account.error ?? "Failed")")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}
