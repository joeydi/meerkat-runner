import Foundation
import Models

/// Proposes the command line of a server that's already running in the folder, for
/// "Add as server…" on an Other listeners row. Uses argv the scanner already read; nothing runs.
public enum RunningProcessProposal {
    /// - Parameters:
    ///   - argv: the running process's arguments (from `KERN_PROCARGS2`).
    ///   - folder: the project folder (the process's working directory).
    ///   - port: the port it's listening on.
    ///   - framework: classifier label, e.g. "Python".
    ///   - rankedFirst: true when no detector found anything, so this becomes the suggestion.
    public static func make(argv: [String], folder: URL, port: Int, framework: String?, rankedFirst: Bool) -> Proposal? {
        guard let executable = argv.first, !executable.isEmpty else { return nil }
        let command = LaunchCommand.argv(relativize(argv, to: folder))
        return Proposal(
            detector: .custom,
            label: command.displayString,
            command: command,
            source: "running on :\(port)",
            framework: framework,
            predictedPort: port,
            // Below every detector unless nothing was detected.
            confidence: rankedFirst ? 1 : 0
        )
    }

    /// Absolute paths inside `folder` become `./relative`, so the command survives the project moving.
    /// The `./` keeps a relative executable from being looked up on PATH instead.
    static func relativize(_ argv: [String], to folder: URL) -> [String] {
        var root = folder.standardizedFileURL.path
        if !root.hasSuffix("/") { root += "/" }
        return argv.map { arg in
            guard arg.hasPrefix(root), arg.count > root.count else { return arg }
            return "./" + arg.dropFirst(root.count)
        }
    }
}
