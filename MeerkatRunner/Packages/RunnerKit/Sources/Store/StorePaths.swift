import Foundation

/// On-disk locations (AGENTS.md §3 "Storage").
public struct StorePaths: Sendable {
    /// `~/Library/Application Support/MeerkatRunner` (mode 0700).
    public var supportDirectory: URL
    /// `~/Library/Logs/MeerkatRunner` (per-project logs, rotated at 5 MB, keep 3).
    public var logsDirectory: URL

    public init(supportDirectory: URL, logsDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.logsDirectory = logsDirectory
    }

    public static var standard: StorePaths {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return StorePaths(
            supportDirectory: library.appendingPathComponent("Application Support/MeerkatRunner", isDirectory: true),
            logsDirectory: library.appendingPathComponent("Logs/MeerkatRunner", isDirectory: true)
        )
    }

    /// `projects.json` (mode 0600).
    public var projectsFile: URL { supportDirectory.appendingPathComponent("projects.json") }
    /// PGIDs Runner launched, for re-adoption after relaunch.
    public var runtimeFile: URL { supportDirectory.appendingPathComponent("runtime.json") }

    public func logFile(for projectID: UUID) -> URL {
        logsDirectory.appendingPathComponent("\(projectID.uuidString).log")
    }
}
