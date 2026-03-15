import DuckoCore
import DuckoData
import SwiftData

struct CLIContext {
    let environment: AppEnvironment
}

@MainActor
enum CLIBootstrap {
    static func setUp(formatter: any CLIFormatter, isInteractive: Bool = false) throws -> CLIContext {
        let container = try ModelContainerFactory.makeContainer()
        let store = SwiftDataPersistenceStore(modelContainer: container)
        let omemoStore = SwiftDataOMEMOStore(modelContainer: container)
        let eventHandler = CLIEventHandler(formatter: formatter, isInteractive: isInteractive)

        let environment = AppEnvironment(
            store: store,
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
