import Foundation
import Models

/// Reads `pnpm-workspace.yaml`, `package.json#workspaces`, `turbo.json`, `nx.json`. Proposes one command
/// per workspace with a `dev` script, run from the repo root. The root `dev` comes from `NodeDetector`.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct MonorepoDetector: Detector {
    public static let id: DetectorID = .monorepo

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        guard !files.workspaces.isEmpty else { return [] }
        let manager = NodeDetector.packageManager(files: files, packageJSON: files.json("package.json"))
        let tool: String? = files.exists("turbo.json") ? "Turborepo" : files.exists("nx.json") ? "Nx" : nil

        return files.workspaces.compactMap { directory in
            let source = "\(directory)/package.json"
            guard let package = files.json(source),
                  let scripts = package["scripts"] as? [String: Any],
                  let body = scripts["dev"] as? String
            else { return nil }
            // yarn needs the package name; npm and pnpm also accept a ./path.
            let workspace = (package["name"] as? String) ?? "./\(directory)"
            let framework = NodeDetector.framework(in: package)
            return Proposal(
                detector: .monorepo,
                label: "\(workspace) dev",
                command: .argv(Self.command(manager: manager.name, workspace: workspace, script: "dev")),
                resolvedScript: NodeDetector.resolvedScript(name: "dev", scripts: scripts),
                source: source,
                framework: framework?.label,
                predictedPort: NodeDetector.predictedPort(script: "dev", body: body, framework: framework),
                confidence: 75,
                notes: tool.map { ["\($0) workspace"] } ?? []
            )
        }
    }

    static func command(manager: String, workspace: String, script: String) -> [String] {
        switch manager {
        case "pnpm": ["pnpm", "--filter", workspace, "run", script]
        case "yarn": ["yarn", "workspace", workspace, "run", script]
        case "bun": ["bun", "run", "--filter", workspace, script]
        default: ["npm", "run", script, "--workspace", workspace]
        }
    }
}
