import Foundation
import Models

/// Reads `pyproject.toml`, `requirements*.txt`. Proposes `uvicorn <module>:app --reload`, `flask run`.
///
/// - Only when the dependency is declared; module guessed from `main.py`/`app.py` and marked low confidence.
/// - Flask's default port 5000 collides with AirPlay Receiver: add a warning note.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct PythonDetector: Detector {
    public static let id: DetectorID = .python

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        // TODO(v0.2): implement per AGENTS.md §5 detector table; add fixtures + expected.json in Tests/Fixtures.
        []
    }
}
