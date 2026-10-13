import Foundation
import Models

/// Reads `Procfile.dev`, `Procfile`. Proposes One proposal per line.
///
/// - Prefer `Procfile.dev`.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct ProcfileDetector: Detector {
    public static let id: DetectorID = .procfile

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        // TODO(v0.2): implement per AGENTS.md §5 detector table; add fixtures + expected.json in Tests/Fixtures.
        []
    }
}
