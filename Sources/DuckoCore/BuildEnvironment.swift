import Foundation

public enum BuildEnvironment {
    #if DEBUG
        private static let profileName = ProcessInfo.processInfo.environment["DUCKO_PROFILE"]

        public static let appSupportDirectoryName: String = {
            if let profile = profileName {
                return "Ducko-Dev-\(profile)"
            }
            return "Ducko-Dev"
        }()

        public static let useKeychain = ProcessInfo.processInfo.environment["DUCKO_USE_KEYCHAIN"] == "1"

        public static let userDefaultsSuiteName: String? = {
            if let profile = profileName {
                return "im.ducko.dev.\(profile)"
            }
            return "im.ducko.dev"
        }()
    #else
        public static let appSupportDirectoryName = "Ducko"
        public static let useKeychain = true
        public static let userDefaultsSuiteName: String? = nil
    #endif

    public static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }
}
