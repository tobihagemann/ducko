import Foundation

public enum BuildEnvironment {
    #if DEBUG
        public static let appSupportDirectoryName = "Ducko-Dev"
        public static let useKeychain = ProcessInfo.processInfo.environment["DUCKO_USE_KEYCHAIN"] == "1"
        public static let userDefaultsSuiteName: String? = "de.tobiha.ducko.dev"
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
