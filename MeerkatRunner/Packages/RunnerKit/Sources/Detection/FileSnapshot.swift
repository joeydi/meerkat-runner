import Foundation

/// The folder's relevant files, read once so detectors don't each hit the disk (AGENTS.md §5).
/// Reads the top level plus known config paths, with a 1 MB cap per file. Never executes anything.
public struct FileSnapshot: Sendable {
    public static let maxFileSize = 1_024 * 1_024

    /// Paths (relative to the folder) whose contents detectors parse.
    public static let knownPaths: [String] = [
        "package.json", "pnpm-workspace.yaml",
        "Procfile.dev", "Procfile",
        "Gemfile", "bin/dev",
        "pyproject.toml",
        "composer.json",
        "Makefile", "justfile",
        "compose.yaml", "compose.yml", "docker-compose.yml",
    ]

    /// Paths only checked for existence (lockfiles, interpreters, markers). Never read.
    public static let probePaths: [String] = [
        "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "package-lock.json",
        "turbo.json", "nx.json",
        "bin/rails", "manage.py", "artisan", "main.py", "app.py",
        ".venv/bin/python", "venv/bin/python",
        ".nvmrc", ".node-version", ".tool-versions", "mise.toml",
        "index.html",
    ]

    public enum Entry: Sendable, Equatable {
        case contents(Data)
        /// Exists but larger than `maxFileSize`; never read.
        case tooLarge
        /// Exists but couldn't be read (permissions, not a regular file, …).
        case unreadable
    }

    /// Top-level names in the folder.
    public var topLevel: Set<String>
    /// Relative path → contents for read paths that exist.
    public var entries: [String: Entry]
    /// Probe paths that exist.
    public var existing: Set<String>
    /// Workspace directories (relative) that contain a `package.json`, sorted.
    public var workspaces: [String]

    public init(topLevel: Set<String>, entries: [String: Entry], existing: Set<String> = [], workspaces: [String] = []) {
        self.topLevel = topLevel
        self.entries = entries
        self.existing = existing
        self.workspaces = workspaces
    }

    public func exists(_ path: String) -> Bool {
        entries[path] != nil || existing.contains(path) || topLevel.contains(path)
    }

    public func data(_ path: String) -> Data? {
        if case .contents(let data) = entries[path] { return data }
        return nil
    }

    public func string(_ path: String) -> String? {
        data(path).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Top-level JSON object, or nil if missing, unreadable, too large, or not an object.
    public func json(_ path: String) -> [String: Any]? {
        data(path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Reads a snapshot of `folder`. Only regular files are read, each capped at `maxFileSize`.
    public static func read(_ folder: URL, extraPaths: [String] = []) -> FileSnapshot {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var entries: [String: Entry] = [:]

        func load(_ relative: String) {
            guard entries[relative] == nil, let entry = readEntry(folder.appendingPathComponent(relative)) else { return }
            entries[relative] = entry
        }

        let requirements = top.filter { $0.hasPrefix("requirements") && $0.hasSuffix(".txt") }.sorted()
        for relative in knownPaths + requirements + extraPaths {
            load(relative)
        }

        var existing = Set<String>()
        for relative in probePaths where fm.fileExists(atPath: folder.appendingPathComponent(relative).path) {
            existing.insert(relative)
        }

        // Workspace package.json files, for the monorepo detector.
        var packageJSON: [String: Any]?
        if case .contents(let data) = entries["package.json"] {
            packageJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        var pnpmWorkspace: String?
        if case .contents(let data) = entries["pnpm-workspace.yaml"] {
            pnpmWorkspace = String(data: data, encoding: .utf8)
        }
        let patterns = Workspaces.patterns(packageJSON: packageJSON, pnpmWorkspace: pnpmWorkspace)
        let workspaceDirs = Workspaces.resolve(patterns, in: folder)
        for dir in workspaceDirs {
            load("\(dir)/package.json")
        }

        return FileSnapshot(
            topLevel: Set(top),
            entries: entries,
            existing: existing,
            workspaces: workspaceDirs.filter { entries["\($0)/package.json"] != nil }
        )
    }

    /// nil when the path doesn't exist.
    static func readEntry(_ url: URL) -> Entry? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        guard attrs[.type] as? FileAttributeType == .typeRegular else { return .unreadable }
        if let size = attrs[.size] as? Int, size > maxFileSize { return .tooLarge }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return .contents(data)
    }
}
