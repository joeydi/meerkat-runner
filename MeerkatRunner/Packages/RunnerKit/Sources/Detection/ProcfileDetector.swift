import Foundation
import Models

/// Reads `Procfile.dev`, else `Procfile`. One proposal per `name: command` line; `resolvedScript` is the line.
/// Lines that need a shell (pipes, variables, …) are proposed as labelled shell commands.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct ProcfileDetector: Detector {
    public static let id: DetectorID = .procfile

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        let (source, base): (String, Int) = files.string("Procfile.dev") != nil ? ("Procfile.dev", 85) : ("Procfile", 65)
        guard let text = files.string(source) else { return [] }

        return Self.entries(in: text).enumerated().map { index, entry in
            Proposal(
                detector: .procfile,
                label: entry.name,
                command: ShellWords.split(entry.command).map(LaunchCommand.argv) ?? .shell(entry.command),
                resolvedScript: entry.line,
                source: source,
                predictedPort: PortPrediction.explicitPort(in: entry.command),
                // Keep file order: earlier lines rank higher.
                confidence: base - index
            )
        }
    }

    struct Entry {
        var name: String
        var command: String
        var line: String
    }

    static func entries(in text: String) -> [Entry] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let command = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !command.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            else { return nil }
            return Entry(name: name, command: command, line: line)
        }
    }
}
