import Foundation

@MainActor @Observable
public final class ChatPreferences {
    private enum Keys {
        static let enableChatStates = "chatEnableChatStates"
        static let enableDisplayedMarkers = "chatEnableDisplayedMarkers"
    }

    private static let defaults = PreferencesDefaults.store

    public static let shared = ChatPreferences()

    public var enableChatStates: Bool {
        didSet { Self.defaults.set(enableChatStates, forKey: Keys.enableChatStates) }
    }

    public var enableDisplayedMarkers: Bool {
        didSet { Self.defaults.set(enableDisplayedMarkers, forKey: Keys.enableDisplayedMarkers) }
    }

    private init() {
        let stored = Self.defaults.object(forKey: Keys.enableChatStates) as? Bool
        self.enableChatStates = stored ?? true
        let storedMarkers = Self.defaults.object(forKey: Keys.enableDisplayedMarkers) as? Bool
        self.enableDisplayedMarkers = storedMarkers ?? true
    }
}
