import Foundation
import Models

/// A folder with an `index.html` and no other project files. Proposes Python's built-in static server,
/// bound to 127.0.0.1. (Runner itself never listens on the network, AGENTS.md §8.1 rule 7, so the
/// "built-in" server is a separate process the user approves like any other.)
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct StaticDetector: Detector {
    public static let id: DetectorID = .static
    public static let port = 8000

    /// Any of these means the folder is a real project, handled by another detector.
    static let manifests = [
        "package.json", "Gemfile", "manage.py", "pyproject.toml", "composer.json", "artisan",
        "Procfile", "Procfile.dev", "Makefile", "justfile", "compose.yaml", "compose.yml", "docker-compose.yml",
    ]

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        guard files.exists("index.html"),
              !Self.manifests.contains(where: files.exists),
              !files.topLevel.contains(where: { $0.hasPrefix("requirements") && $0.hasSuffix(".txt") })
        else { return [] }
        let command = LaunchCommand.argv(["python3", "-m", "http.server", String(Self.port), "--bind", LocalhostBinding.address])
        return [Proposal(
            detector: .static,
            label: "Static site",
            command: command,
            source: "index.html",
            framework: "Static",
            predictedPort: Self.port,
            confidence: 30,
            notes: ["Python's built-in server"]
        )]
    }
}
