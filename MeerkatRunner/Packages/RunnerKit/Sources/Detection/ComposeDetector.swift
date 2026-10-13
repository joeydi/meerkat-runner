import Foundation
import Models

/// Reads `compose.yaml`, `compose.yml`, `docker-compose.yml`. Proposes `docker compose up`, with ports
/// from `ports:`. Container control beyond this command is out of scope (AGENTS.md §1).
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct ComposeDetector: Detector {
    public static let id: DetectorID = .compose
    public static let fileNames = ["compose.yaml", "compose.yml", "docker-compose.yml"]

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        guard let source = Self.fileNames.first(where: { files.string($0) != nil }),
              let text = files.string(source)
        else { return [] }
        return [Proposal(
            detector: .compose,
            label: "docker compose up",
            command: .argv(["docker", "compose", "up"]),
            source: source,
            framework: "Docker",
            predictedPort: Self.hostPorts(in: text).first,
            confidence: 30,
            notes: ["Docker"]
        )]
    }

    /// Host ports from short (`- "8080:80"`, `- 127.0.0.1:5432:5432`) and long (`published: 8080`) syntax.
    static func hostPorts(in yaml: String) -> [Int] {
        let patterns = [
            #"^\s*-\s*["']?(?:[0-9.]+:)?(\d{2,5}):\d{1,5}"#,
            #"^\s*published:\s*["']?(\d{2,5})"#,
        ]
        let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        var ports: [Int] = []
        for line in yaml.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            for regex in regexes {
                if let match = regex.firstMatch(in: line, range: range),
                   let portRange = Range(match.range(at: 1), in: line),
                   let port = Int(line[portRange]) {
                    ports.append(port)
                    break
                }
            }
        }
        return ports
    }
}
