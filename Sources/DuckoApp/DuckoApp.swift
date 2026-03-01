import AppKit
import DuckoCore
import DuckoData
import DuckoUI
import SwiftData
import SwiftUI

@main
struct DuckoApp: App {
    @State private var environment: AppEnvironment

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        do {
            let container = try ModelContainerFactory.makeContainer()
            let store = SwiftDataPersistenceStore(modelContainer: container)
            self.environment = AppEnvironment(store: store)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        Window("Contacts", id: "contacts") {
            ContentView()
                .environment(environment)
        }
        .defaultSize(width: 280, height: 600)

        WindowGroup("Chat", id: "chat", for: String.self) { $jidString in
            ChatWindow(jidString: $jidString)
                .environment(environment)
        }
        .defaultSize(width: 500, height: 450)

        MenuBarExtra("Ducko", systemImage: "bubble.left.and.bubble.right.fill") {
            MenuBarStatusView()
                .environment(environment)
        }
    }
}
