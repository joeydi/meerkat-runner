import Foundation
import Models

/// Reads `manage.py`. Proposes `<python> manage.py runserver`, where `<python>` is `.venv/bin/python`,
/// `venv/bin/python`, else `python3`.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct DjangoDetector: Detector {
    public static let id: DetectorID = .django

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        guard files.exists("manage.py") else { return [] }
        let command = LaunchCommand.argv([PythonInterpreter.path(in: files), "manage.py", "runserver"])
        return [Proposal(
            detector: .django,
            label: command.displayString,
            command: command,
            source: "manage.py",
            framework: "Django",
            predictedPort: 8000,
            confidence: 90
        )]
    }
}
