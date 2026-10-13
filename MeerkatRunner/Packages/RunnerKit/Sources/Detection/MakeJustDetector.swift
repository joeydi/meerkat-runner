import Foundation
import Models

/// Reads `Makefile`, `justfile`. Proposes targets named `dev`, `run`, `serve`, `start`.
/// Parses target names only; `resolvedScript` is the recipe lines.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct MakeJustDetector: Detector {
    public static let id: DetectorID = .make

    public static let targetNames: Set<String> = ["dev", "run", "serve", "start"]

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        var proposals: [Proposal] = []
        if let text = files.string("Makefile") {
            proposals += Self.proposals(Self.makeTargets(in: text), tool: "make", detector: .make, source: "Makefile")
        }
        if let text = files.string("justfile") {
            proposals += Self.proposals(Self.justRecipes(in: text), tool: "just", detector: .just, source: "justfile")
        }
        return proposals
    }

    struct Target: Equatable {
        var name: String
        var recipe: [String]
    }

    static func proposals(_ targets: [Target], tool: String, detector: DetectorID, source: String) -> [Proposal] {
        targets.filter { targetNames.contains($0.name) }.map { target in
            let recipe = target.recipe.joined(separator: "\n")
            return Proposal(
                detector: detector,
                label: "\(tool) \(target.name)",
                command: .argv([tool, target.name]),
                resolvedScript: recipe.isEmpty ? nil : recipe,
                source: source,
                predictedPort: PortPrediction.explicitPort(in: recipe),
                confidence: 50
            )
        }
    }

    /// `name: deps` headers (not `:=` / `::=` assignments), with following tab-indented recipe lines.
    static func makeTargets(in text: String) -> [Target] {
        parse(text, header: #"^([A-Za-z0-9_.-]+)\s*:(?![=:])"#) { $0.hasPrefix("\t") }
    }

    /// `name args:` headers (optionally `@`-quiet), with following indented recipe lines.
    static func justRecipes(in text: String) -> [Target] {
        parse(text, header: #"^@?([A-Za-z0-9_-]+)(?:\s+[^:=]*)?:(?!=)"#) { $0.hasPrefix(" ") || $0.hasPrefix("\t") }
    }

    private static func parse(_ text: String, header: String, isRecipe: (String) -> Bool) -> [Target] {
        guard let regex = try? NSRegularExpression(pattern: header) else { return [] }
        var targets: [Target] = []
        var current: Target?
        for raw in text.components(separatedBy: .newlines) {
            if current != nil, isRecipe(raw) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { current?.recipe.append(line) }
                continue
            }
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let finished = current { targets.append(finished) }
            current = nil
            let range = NSRange(raw.startIndex..., in: raw)
            if let match = regex.firstMatch(in: raw, range: range), let name = Range(match.range(at: 1), in: raw),
               !raw[name].hasPrefix(".") {
                current = Target(name: String(raw[name]), recipe: [])
            }
        }
        if let finished = current { targets.append(finished) }
        return targets
    }
}
