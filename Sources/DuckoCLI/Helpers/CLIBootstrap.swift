import DuckoCore
import DuckoData
import SwiftData

struct CLIContext: Sendable {
    let environment: AppEnvironment
}

@MainActor
enum CLIBootstrap {
    static func setUp(formatter: any CLIFormatter) throws -> CLIContext {
        let container = try ModelContainerFactory.makeContainer()
        let store = SwiftDataPersistenceStore(modelContainer: container)
        let eventHandler = CLIEventHandler(formatter: formatter)

        let environment = AppEnvironment(
            store: store,
            onExternalEvent: { event, accountID in
                Task {
                    await eventHandler.handleEvent(event, accountID: accountID)
                }
            }
        )

        return CLIContext(environment: environment)
    }
}
