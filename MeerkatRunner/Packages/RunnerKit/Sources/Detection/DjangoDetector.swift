import Foundation
import Models

/// Reads `manage.py`. Proposes `<python> manage.py runserver`.
///
/// - `<python>` = `.venv/bin/python`, `venv/bin/python`, else `python3`.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct DjangoDetector: Detector {
    public static let id: DetectorID = .django

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        // TODO(v0.2): implement per AGENTS.md §5 detector table; add fixtures + expected.json in Tests/Fixtures.
        []
    }
}
