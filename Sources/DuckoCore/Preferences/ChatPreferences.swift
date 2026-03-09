import Foundation

@MainActor @Observable
public final class ChatPreferences {
    private enum Keys {
        static let enableChatStates = "chatEnableChatStates"
    }

    private nonisolated(unsafe) static let defaults: UserDefaults = {
        if let suite = BuildEnvironment.userDefaultsSuiteName {
            return UserDefaults(suiteName: suite) ?? .standard
        }
        return .standard
    }()

    public static let shared = ChatPreferences()

    public var enableChatStates: Bool {
        didSet { Self.defaults.set(enableChatStates, forKey: Keys.enableChatStates) }
    }

    private init() {
        let stored = Self.defaults.object(forKey: Keys.enableChatStates) as? Bool
        self.enableChatStates = stored ?? true
    }
}
