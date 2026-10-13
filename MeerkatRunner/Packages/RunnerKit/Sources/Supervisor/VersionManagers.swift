import Foundation

/// Per-project version-manager wrappers (AGENTS.md §6.1). Used only when the manager is installed;
/// otherwise the captured PATH is used as-is. The chosen wrapper is part of the fingerprint (§8.2).
public enum VersionManagers {
    public struct Entry: Sendable, Equatable {
        /// Marker file in the project root.
        public var file: String
        /// Executable name looked up on the captured PATH.
        public var executable: String
        /// Arguments placed before the command.
        public var prefix: [String]
    }

    /// Ordered: the first entry whose file exists and executable is installed wins.
    public static let table: [Entry] = [
        Entry(file: "mise.toml", executable: "mise", prefix: ["mise", "exec", "--"]),
        Entry(file: ".tool-versions", executable: "mise", prefix: ["mise", "exec", "--"]),
        Entry(file: ".tool-versions", executable: "asdf", prefix: ["asdf", "exec"]),
        Entry(file: ".node-version", executable: "fnm", prefix: ["fnm", "exec", "--"]),
        Entry(file: ".nvmrc", executable: "fnm", prefix: ["fnm", "exec", "--"]),
    ]

    /// - Parameters:
    ///   - existingFiles: marker files present in the project root.
    ///   - isInstalled: whether an executable is on the captured PATH.
    public static func wrapper(existingFiles: Set<String>, isInstalled: (String) -> Bool) -> [String] {
        table.first { existingFiles.contains($0.file) && isInstalled($0.executable) }?.prefix ?? []
    }
}
