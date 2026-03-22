import Foundation

/// Represents a discovered Adium service/account directory with its contacts and file counts.
public struct AdiumServiceAccount: Sendable {
    public let service: String
    public let accountUID: String
    public let directoryURL: URL
    public let contactDirectories: [URL]
    public let fileCount: Int
}

/// Scans an Adium logs directory and enumerates available service accounts and log files.
public enum AdiumLogDiscovery {
    /// Default Adium logs path.
    public static let defaultLogsURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Adium 2.0/Users/Default/Logs")

    /// Discovers all service accounts under the given Adium logs directory.
    ///
    /// Directory structure: `Logs/SERVICE.ACCOUNT_UID/CONTACT_UID/*.chatlog/*.xml`
    public static func discoverSources(at logsURL: URL) throws -> [AdiumServiceAccount] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logsURL.path) else {
            return []
        }

        let serviceAccountDirs = try fm.contentsOfDirectory(
            at: logsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        return try serviceAccountDirs.compactMap { serviceAccountURL -> AdiumServiceAccount? in
            let dirName = serviceAccountURL.lastPathComponent
            guard let dotIndex = dirName.firstIndex(of: ".") else { return nil }

            let service = String(dirName[..<dotIndex])
            let accountUID = String(dirName[dirName.index(after: dotIndex)...])
            guard !service.isEmpty, !accountUID.isEmpty else { return nil }

            let contactDirs = try fm.contentsOfDirectory(
                at: serviceAccountURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

            let fileCount = contactDirs.reduce(0) { total, contactDir in
                total + ((try? logFileURLs(in: contactDir).count) ?? 0)
            }

            return AdiumServiceAccount(
                service: service,
                accountUID: accountUID,
                directoryURL: serviceAccountURL,
                contactDirectories: contactDirs,
                fileCount: fileCount
            )
        }.sorted { $0.service < $1.service || ($0.service == $1.service && $0.accountUID < $1.accountUID) }
    }

    /// Enumerates all log file URLs (XML, HTML, AdiumHTMLLog) within a contact directory.
    public static func logFileURLs(in contactDirectory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: contactDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "xml" || ext == "html" || ext == "adiumhtmllog" {
                urls.append(fileURL)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }
}
