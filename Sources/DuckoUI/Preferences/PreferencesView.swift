import SwiftUI

public struct PreferencesView: View {
    public init() {}

    public var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("General", systemImage: "gearshape") }

            AccountsPreferencesView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }

            ChatPreferencesView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }

            AppearancePreferencesView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            NotificationsPreferencesView()
                .tabItem { Label("Notifications", systemImage: "bell") }

            AdvancedPreferencesView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 550, height: 400)
    }
}
