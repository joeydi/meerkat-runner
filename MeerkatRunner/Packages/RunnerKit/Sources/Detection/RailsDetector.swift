import Foundation
import Models

/// Reads `Gemfile`, `bin/dev`, `bin/rails`. Proposes `bin/dev`, else `bin/rails server`.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct RailsDetector: Detector {
    public static let id: DetectorID = .rails

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        // TODO(v0.2): implement per AGENTS.md §5 detector table; add fixtures + expected.json in Tests/Fixtures.
        []
    }
}
