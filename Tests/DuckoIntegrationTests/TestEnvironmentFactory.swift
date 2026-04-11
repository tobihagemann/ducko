import DuckoData
import DuckoXMPP
import Foundation
@testable import DuckoCore

/// Factory for fully isolated `AppEnvironment` instances backed by in-memory
/// SwiftData and a private temp directory for transcripts and credentials.
///
/// Mirrors `CLIBootstrap.setUp` and `DuckoApp.init` but swaps every persistent
/// store for a throw-away one so tests never touch developer data.
@MainActor
enum TestEnvironmentFactory {
    /// Creates an isolated `AppEnvironment` plus the temp directory it owns.
    /// Callers are responsible for removing the temp directory in teardown.
    static func makeEnvironment(
        onExternalEvent: (@Sendable (XMPPEvent, UUID) -> Void)? = nil
    ) throws -> (environment: AppEnvironment, tempDirectory: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ducko-inttest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        do {
            let container = try ModelContainerFactory.makeContainer(inMemory: true)
            let store = SwiftDataPersistenceStore(modelContainer: container)
            let omemoStore = SwiftDataOMEMOStore(modelContainer: container)
            let transcripts = FileTranscriptStore(baseDirectory: tempDir.appendingPathComponent("Transcripts", isDirectory: true))
            let credentialStore = FileCredentialStore(fileURL: tempDir.appendingPathComponent("credentials.json"))

            let environment = AppEnvironment(
                store: store,
                transcripts: transcripts,
                credentialStore: credentialStore,
                omemoStore: omemoStore,
                onExternalEvent: onExternalEvent
            )

            return (environment, tempDir)
        } catch {
            // Clean up the temp dir we just created — `withHarness` only owns the
            // teardown path once makeEnvironment returns successfully.
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }
}
