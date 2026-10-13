import Foundation
import Models

/// Reads `pnpm-workspace.yaml`, `package.json#workspaces`, `turbo.json`, `nx.json`. Proposes Root `dev` plus one proposal per workspace with a `dev` script.
///
/// - The Add sheet offers "Add each as its own server" (v0.3).
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct MonorepoDetector: Detector {
    public static let id: DetectorID = .monorepo

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        // TODO(v0.2): implement per AGENTS.md §5 detector table; add fixtures + expected.json in Tests/Fixtures.
        []
    }
}
