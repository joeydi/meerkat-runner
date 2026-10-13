import Foundation
import Models

/// Reads `compose.yaml`, `compose.yml`, `docker-compose.yml`. Proposes `docker compose up`.
///
/// - Ports from `ports:`; add a "Docker" note.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct ComposeDetector: Detector {
    public static let id: DetectorID = .compose

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        // TODO(v0.2): implement per AGENTS.md §5 detector table; add fixtures + expected.json in Tests/Fixtures.
        []
    }
}
