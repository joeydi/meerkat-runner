import Foundation
import Models

/// Matches listeners to registered projects (AGENTS.md §4 "Matching listeners to projects").
public struct ProjectMatcher: Sendable {
    /// PGIDs Runner launched, keyed by project (from the supervisor or `runtime.json`).
    public var launchedGroups: [pid_t: UUID]

    public init(launchedGroups: [pid_t: UUID] = [:]) {
        self.launchedGroups = launchedGroups
    }

    /// Returns the matching project's ID, choosing the deepest path when several match.
    ///
    /// TODO(v0.1/v0.2): rule 2 must walk ancestor cwds up to (not including) the first shell or
    /// `launchd`; paths must be canonicalised (`realpath`, case-insensitive on case-insensitive volumes).
    public func match(_ listener: Listener, projects: [Project]) -> UUID? {
        // 1. PGID launched by Runner.
        if let id = launchedGroups[listener.pgid] { return id }

        // 2. cwd inside P.path (ancestors: TODO).
        // 3. argv contains an absolute path inside P.path.
        let candidates = projects.filter { project in
            if let cwd = listener.cwd, Self.isPath(cwd, inside: project.path) { return true }
            return listener.argv.contains { $0.hasPrefix("/") && Self.isPath($0, inside: project.path) }
        }
        return candidates.max { $0.path.count < $1.path.count }?.id
    }

    static func isPath(_ path: String, inside root: String) -> Bool {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == root || path.hasPrefix(root + "/")
    }
}
