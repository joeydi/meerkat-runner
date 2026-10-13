import Foundation

/// A registered dev server. Persisted in `projects.json` (AGENTS.md §3).
public struct Project: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    /// Display name, e.g. "docs".
    public var name: String
    /// Canonical realpath of the project folder.
    public var path: String
    /// Regular (non-security-scoped) bookmark, so the project survives folder moves.
    public var bookmark: Data?
    public var detector: DetectorID
    public var command: LaunchCommand
    /// User-entered environment overrides. Values are never logged.
    public var envOverrides: [String: String]
    /// Env files relative to `path`, e.g. `[".env.local"]`.
    public var envFiles: [String]
    /// Predicted or user-entered port.
    public var expectedPort: Int?
    /// Port observed on a real run (§6.4).
    public var learnedPort: Int?
    public var healthURL: URL?
    public var autoStartAtLogin: Bool
    /// Ask the framework to bind 127.0.0.1 (§6.6).
    public var preferLocalhostBind: Bool
    /// The flags or env that `preferLocalhostBind` adds, decided when the project was added. Part of
    /// the approved, fingerprinted command; nil when off (and for projects saved before v0.3).
    public var localhostBind: BindOverride?
    /// `nil` = never approved; the project cannot start.
    public var approval: Approval?
    /// Reserved for the Meerkat integration (later).
    public var liveURL: URL?

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        bookmark: Data? = nil,
        detector: DetectorID,
        command: LaunchCommand,
        envOverrides: [String: String] = [:],
        envFiles: [String] = [],
        expectedPort: Int? = nil,
        learnedPort: Int? = nil,
        healthURL: URL? = nil,
        autoStartAtLogin: Bool = false,
        preferLocalhostBind: Bool = false,
        localhostBind: BindOverride? = nil,
        approval: Approval? = nil,
        liveURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.detector = detector
        self.command = command
        self.envOverrides = envOverrides
        self.envFiles = envFiles
        self.expectedPort = expectedPort
        self.learnedPort = learnedPort
        self.healthURL = healthURL
        self.autoStartAtLogin = autoStartAtLogin
        self.preferLocalhostBind = preferLocalhostBind
        self.localhostBind = localhostBind
        self.approval = approval
        self.liveURL = liveURL
    }

    /// The port to show/open: learned beats expected.
    public var port: Int? { learnedPort ?? expectedPort }

    /// What actually runs: `command` plus any localhost-bind arguments. This, not `command`, is what
    /// gets approved, fingerprinted and spawned. `command` stays the detector's own form so the
    /// script can be re-resolved from the files.
    public var launchCommand: LaunchCommand {
        guard preferLocalhostBind, let bind = localhostBind else { return command }
        return command.appending(bind.arguments)
    }

    /// Env names and values added by the localhost bind (e.g. `HOST=127.0.0.1`).
    public var bindEnvironment: [String: String] {
        guard preferLocalhostBind, let bind = localhostBind else { return [:] }
        return bind.environment
    }
}

/// What "Bind to localhost only" adds for a framework (AGENTS.md §6.6): arguments appended to the
/// command (e.g. `--host 127.0.0.1`) and/or environment (e.g. `HOST=127.0.0.1`).
public struct BindOverride: Codable, Sendable, Hashable {
    public var arguments: [String]
    public var environment: [String: String]

    public init(arguments: [String] = [], environment: [String: String] = [:]) {
        self.arguments = arguments
        self.environment = environment
    }

    public var isEmpty: Bool { arguments.isEmpty && environment.isEmpty }
}

/// How a project starts. `.argv` is the default; `.shell` is opt-in and labelled in the UI.
public enum LaunchCommand: Codable, Sendable, Hashable {
    /// e.g. `["pnpm", "run", "dev"]`. Spawned directly, never through a shell.
    case argv([String])
    /// Run as `[$SHELL, "-c", string]`. Only allowed when the user explicitly saved a shell command.
    case shell(String)

    /// The exact text shown to the user for approval and diffs.
    public var displayString: String {
        switch self {
        case .argv(let args):
            return args.map(Self.quoteForDisplay).joined(separator: " ")
        case .shell(let string):
            return string
        }
    }

    /// The command with `arguments` appended. Shell commands get each argument single-quoted.
    public func appending(_ arguments: [String]) -> LaunchCommand {
        guard !arguments.isEmpty else { return self }
        switch self {
        case .argv(let args):
            return .argv(args + arguments)
        case .shell(let string):
            let quoted = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            return .shell(([string] + quoted).joined(separator: " "))
        }
    }

    public var isShell: Bool {
        if case .shell = self { return true }
        return false
    }

    /// Display-only quoting so arguments with spaces stay unambiguous. Never used to build a command.
    private static func quoteForDisplay(_ arg: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@%+,"))
        if !arg.isEmpty, arg.unicodeScalars.allSatisfy(safe.contains) {
            return arg
        }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A user's approval of a specific command in a specific form (§8.2).
public struct Approval: Codable, Sendable, Equatable {
    /// Hex SHA-256 from `ScriptFingerprint`.
    public var fingerprint: String
    public var approvedAt: Date
    /// Exactly what the user saw, for the re-approval diff.
    public var displayedCommand: String
    /// e.g. the `package.json` `scripts.dev` body, including pre/post hooks.
    public var resolvedScript: String?

    public init(fingerprint: String, approvedAt: Date, displayedCommand: String, resolvedScript: String?) {
        self.fingerprint = fingerprint
        self.approvedAt = approvedAt
        self.displayedCommand = displayedCommand
        self.resolvedScript = resolvedScript
    }
}

/// Which detector produced a project's command.
public enum DetectorID: String, Codable, Sendable, CaseIterable {
    case node
    case monorepo
    case procfile
    case rails
    case django
    case python
    case laravel
    case make
    case just
    case compose
    case `static`
    case custom
}
