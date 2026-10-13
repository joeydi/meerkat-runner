import Foundation

/// The folder's relevant files, read once so detectors don't each hit the disk (AGENTS.md §5).
/// Reads the top level plus known config paths, with a 1 MB cap per file.
public struct FileSnapshot: Sendable {
    public static let maxFileSize = 1_024 * 1_024

    /// Known paths (relative to the folder) read beyond the top-level listing.
    public static let knownPaths: [String] = [
        "package.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "package-lock.json",
        "pnpm-workspace.yaml", "turbo.json", "nx.json",
        "Procfile.dev", "Procfile",
        "Gemfile", "bin/dev", "bin/rails",
        "manage.py", ".venv/bin/python", "venv/bin/python",
        "pyproject.toml", "requirements.txt", "requirements-dev.txt", "main.py", "app.py",
        "artisan", "composer.json",
        "Makefile", "justfile",
        "compose.yaml", "compose.yml", "docker-compose.yml",
        ".nvmrc", ".node-version", ".tool-versions", "mise.toml",
        "index.html",
    ]

    public enum Entry: Sendable, Equatable {
        case contents(Data)
        /// Exists but larger than `maxFileSize`; never read.
        case tooLarge
        /// Exists but couldn't be read (permissions etc.).
        case unreadable
    }

    /// Top-level names in the folder.
    public var topLevel: Set<String>
    /// Relative path → contents for known paths that exist.
    public var entries: [String: Entry]

    public init(topLevel: Set<String>, entries: [String: Entry]) {
        self.topLevel = topLevel
        self.entries = entries
    }

    public func exists(_ path: String) -> Bool {
        entries[path] != nil || topLevel.contains(path)
    }

    public func data(_ path: String) -> Data? {
        if case .contents(let data) = entries[path] { return data }
        return nil
    }

    public func string(_ path: String) -> String? {
        data(path).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Reads a snapshot of `folder`. Never follows the folder outside itself and never executes anything.
    public static func read(_ folder: URL, extraPaths: [String] = []) -> FileSnapshot {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var entries: [String: Entry] = [:]
        for relative in knownPaths + extraPaths {
            let url = folder.appendingPathComponent(relative)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            if let size = attrs[.size] as? Int, size > maxFileSize {
                entries[relative] = .tooLarge
            } else if let data = try? Data(contentsOf: url) {
                entries[relative] = .contents(data)
            } else {
                entries[relative] = .unreadable
            }
        }
        return FileSnapshot(topLevel: Set(top), entries: entries)
    }
}
