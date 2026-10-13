import Foundation
import Models

/// Reads `Gemfile`, `bin/dev`, `bin/rails`. Proposes `bin/dev`, else `bin/rails server`.
/// `bin/dev` is a script, so its contents are the resolved script shown for approval.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct RailsDetector: Detector {
    public static let id: DetectorID = .rails

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        let gemfileHasRails = files.string("Gemfile").map {
            $0.range(of: #"(?m)^\s*gem\s+["']rails["']"#, options: .regularExpression) != nil
        } ?? false
        guard gemfileHasRails || files.exists("bin/rails") else { return [] }

        var proposals: [Proposal] = []
        if files.exists("bin/dev") {
            let script = files.string("bin/dev")?.trimmedScript
            proposals.append(Proposal(
                detector: .rails,
                label: "bin/dev",
                command: .argv(["bin/dev"]),
                resolvedScript: script,
                source: "bin/dev",
                framework: "Rails",
                predictedPort: script.flatMap(PortPrediction.explicitPort(in:)) ?? 3000,
                confidence: 95
            ))
        }
        if files.exists("bin/rails") {
            proposals.append(Proposal(
                detector: .rails,
                label: "bin/rails server",
                command: .argv(["bin/rails", "server"]),
                source: "bin/rails",
                framework: "Rails",
                predictedPort: 3000,
                confidence: 85
            ))
        }
        return proposals
    }
}
