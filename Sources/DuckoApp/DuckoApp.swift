import DuckoCore
import DuckoData
import DuckoUI
import SwiftData
import SwiftUI

@main
struct DuckoApp: App {
    @State private var environment: AppEnvironment

    init() {
        do {
            let container = try ModelContainerFactory.makeContainer()
            let store = SwiftDataPersistenceStore(modelContainer: container)
            self.environment = AppEnvironment(store: store)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(environment)
        }
    }
}
