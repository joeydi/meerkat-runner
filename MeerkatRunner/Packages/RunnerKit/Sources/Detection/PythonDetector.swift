import Foundation
import Models

/// Reads `pyproject.toml`, `requirements*.txt`. Proposes `uvicorn <module>:app --reload` and `flask run`,
/// only when the dependency is declared. Run through the project's interpreter (`python -m …`) so a
/// virtualenv's packages are used without it being on PATH.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct PythonDetector: Detector {
    public static let id: DetectorID = .python

    public static let airPlayNote = "Port 5000 is also used by AirPlay Receiver"

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        let sources = (["pyproject.toml"] + files.topLevel.filter { $0.hasPrefix("requirements") && $0.hasSuffix(".txt") }.sorted())
            .filter { files.string($0) != nil }
        let python = PythonInterpreter.path(in: files)
        var proposals: [Proposal] = []

        if let source = sources.first(where: { Self.declares("uvicorn", in: files.string($0)!) }) {
            // Module is a guess, so this ranks low.
            let module = files.exists("main.py") ? "main" : files.exists("app.py") ? "app" : "main"
            let command = LaunchCommand.argv([python, "-m", "uvicorn", "\(module):app", "--reload"])
            proposals.append(Proposal(
                detector: .python,
                label: command.displayString,
                command: command,
                source: source,
                framework: "Python",
                predictedPort: 8000,
                confidence: 40,
                notes: ["module guessed from \(module).py"]
            ))
        }
        if let source = sources.first(where: { Self.declares("flask", in: files.string($0)!) }) {
            let command = LaunchCommand.argv([python, "-m", "flask", "run"])
            proposals.append(Proposal(
                detector: .python,
                label: command.displayString,
                command: command,
                source: source,
                framework: "Flask",
                predictedPort: 5000,
                confidence: 60,
                notes: [Self.airPlayNote]
            ))
        }
        return proposals
    }

    /// True when `package` appears as a dependency name in requirements or pyproject syntax.
    static func declares(_ package: String, in text: String) -> Bool {
        let pattern = #"(?im)(^|["'\s,\[])"# + NSRegularExpression.escapedPattern(for: package) + #"(?=$|[\s"',;<>=~!\[\]])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
