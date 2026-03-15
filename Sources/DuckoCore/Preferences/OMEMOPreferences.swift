import Foundation

@MainActor @Observable
public final class OMEMOPreferences {
    private enum Keys {
        static let trustOnFirstUse = "omemoTrustOnFirstUse"
        static let encryptByDefault = "omemoEncryptByDefault"
    }

    private nonisolated(unsafe) static let defaults: UserDefaults = {
        if let suite = BuildEnvironment.userDefaultsSuiteName {
            return UserDefaults(suiteName: suite) ?? .standard
        }
        return .standard
    }()

    public static let shared = OMEMOPreferences()

    public var trustOnFirstUse: Bool {
        didSet { Self.defaults.set(trustOnFirstUse, forKey: Keys.trustOnFirstUse) }
    }

    public var encryptByDefault: Bool {
        didSet { Self.defaults.set(encryptByDefault, forKey: Keys.encryptByDefault) }
    }

    private init() {
        let storedTOFU = Self.defaults.object(forKey: Keys.trustOnFirstUse) as? Bool
        self.trustOnFirstUse = storedTOFU ?? false
        let storedDefault = Self.defaults.object(forKey: Keys.encryptByDefault) as? Bool
        self.encryptByDefault = storedDefault ?? false
    }
}
