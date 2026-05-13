import Darwin
import DuckoCore
import DuckoData
import SwiftData

struct CLIContext {
    let environment: AppEnvironment
}

@MainActor
enum CLIBootstrap {
    static func setUp(formatter: any CLIFormatter, isInteractive: Bool = false) throws -> CLIContext {
        // Ignore SIGPIPE so a broken pipe `write()` returns `EPIPE` to the
        // caller instead of terminating the process — the standard Unix idiom
        // for CLI tools. Writes most commonly broken-pipe when an XMPP TCP
        // socket's peer closes mid-stream; without this, the integration
        // harness sees an empty-output `nonZeroExit(code: 13)` (signal 13 =
        // SIGPIPE) with no way to recover or surface a real error message.
        signal(SIGPIPE, SIG_IGN)

        LoggingConfiguration.bootstrap()
        let container = try ModelContainerFactory.makeContainer()
        let store = SwiftDataPersistenceStore(modelContainer: container)
        let omemoStore = SwiftDataOMEMOStore(modelContainer: container)
        let eventHandler = CLIEventHandler(formatter: formatter, isInteractive: isInteractive)

        let transcripts = FileTranscriptStore.makeDefault()

        let environment = AppEnvironment(
            store: store,
            transcripts: transcripts,
            omemoStore: omemoStore,
            onExternalEvent: { event, accountID in
                Task {
                    await eventHandler.handleEvent(event, accountID: accountID)
                }
            }
        )

        return CLIContext(environment: environment)
    }
}
