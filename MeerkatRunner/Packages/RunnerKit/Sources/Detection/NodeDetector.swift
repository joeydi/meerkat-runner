import Foundation
import Models

/// Reads `package.json` and lockfiles. Proposes `<pm> run <script>` for `dev`, `start`, `serve`,
/// `develop`, `preview` (that order), per AGENTS.md §5.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct NodeDetector: Detector {
    public static let id: DetectorID = .node

    public static let scriptOrder = ["dev", "start", "serve", "develop", "preview"]
    static let confidence = ["dev": 100, "start": 90, "serve": 80, "develop": 70, "preview": 60]

    /// Framework by dependency, checked in order. A key ending in `/` matches any package with that prefix.
    static let frameworks: [(dependency: String, name: String)] = [
        ("next", "Next.js"),
        ("nuxt", "Nuxt"),
        ("astro", "Astro"),
        ("@remix-run/", "Remix"),
        ("@sveltejs/kit", "SvelteKit"),
        ("vite", "Vite"),
    ]

    /// `preview` serves a production build on a different port than `dev` for these.
    static let previewPorts = ["Vite": 4173, "SvelteKit": 4173]

    public struct PackageManager: Sendable, Equatable {
        public var name: String
        /// The lockfile that decided it, if any.
        public var lockfile: String?
    }

    public struct Framework: Sendable, Equatable {
        public var name: String
        /// Major version from the dependency range, e.g. "15".
        public var majorVersion: String?

        public var label: String { [name, majorVersion].compactMap { $0 }.joined(separator: " ") }
    }

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        guard let package = files.json("package.json"), let scripts = package["scripts"] as? [String: Any] else {
            return []
        }
        let manager = Self.packageManager(files: files, packageJSON: package)
        let framework = Self.framework(in: package)

        return Self.scriptOrder.compactMap { name in
            guard let body = scripts[name] as? String else { return nil }
            var notes: [String] = []
            if name == "start", let framework, ["Next.js", "Nuxt"].contains(framework.name) {
                notes.append("needs a build first")
            }
            return Proposal(
                detector: .node,
                label: "\(manager.name) \(name)",
                command: .argv([manager.name, "run", name]),
                resolvedScript: Self.resolvedScript(name: name, scripts: scripts),
                source: "package.json",
                framework: framework?.label,
                predictedPort: Self.predictedPort(script: name, body: body, framework: framework),
                confidence: Self.confidence[name] ?? 50,
                notes: notes
            )
        }
    }

    static let lockfiles = [
        ("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"), ("bun.lock", "bun"),
        ("package-lock.json", "npm"),
    ]

    /// Lockfile first, then the `packageManager` field; for a package inside a monorepo, then the
    /// root's lockfile and field; else npm.
    public static func packageManager(files: FileSnapshot, packageJSON: [String: Any]?) -> PackageManager {
        for (lockfile, name) in lockfiles where files.exists(lockfile) {
            return PackageManager(name: name, lockfile: lockfile)
        }
        if let name = managerName(packageJSON?["packageManager"] as? String) {
            return PackageManager(name: name, lockfile: nil)
        }
        if let root = files.workspaceRoot {
            for (lockfile, name) in lockfiles where root.lockfiles.contains(lockfile) {
                return PackageManager(name: name, lockfile: "\(root.relativePath)/\(lockfile)")
            }
            if let name = managerName(root.packageManager) {
                return PackageManager(name: name, lockfile: nil)
            }
        }
        return PackageManager(name: "npm", lockfile: nil)
    }

    /// `pnpm@9.1.0` → `pnpm`.
    static func managerName(_ field: String?) -> String? {
        guard let name = field?.split(separator: "@").first.map(String.init),
              ["pnpm", "yarn", "bun", "npm"].contains(name)
        else { return nil }
        return name
    }

    public static func framework(in package: [String: Any]) -> Framework? {
        let dependencies = (package["dependencies"] as? [String: Any] ?? [:])
            .merging(package["devDependencies"] as? [String: Any] ?? [:]) { first, _ in first }
        for (dependency, name) in frameworks {
            let key: String? = if dependency.hasSuffix("/") {
                dependencies.keys.sorted().first { $0.hasPrefix(dependency) }
            } else {
                dependencies[dependency] != nil ? dependency : nil
            }
            guard let key else { continue }
            return Framework(name: name, majorVersion: majorVersion(dependencies[key] as? String))
        }
        return nil
    }

    /// `^15.0.0` → "15". nil for tags (`latest`), URLs and workspace ranges.
    static func majorVersion(_ range: String?) -> String? {
        guard let range else { return nil }
        let start = range.drop { "^~>=<v ".contains($0) }
        let digits = start.prefix { $0.isNumber }
        guard !digits.isEmpty, start.dropFirst(digits.count).first.map({ $0 == "." }) ?? true else { return nil }
        return String(digits)
    }

    /// The script body plus any `pre<name>` / `post<name>` hooks, which npm runs automatically and so
    /// must be shown and fingerprinted (AGENTS.md §14).
    public static func resolvedScript(name: String, scripts: [String: Any]) -> String? {
        guard let body = scripts[name] as? String else { return nil }
        let pre = scripts["pre\(name)"] as? String
        let post = scripts["post\(name)"] as? String
        guard pre != nil || post != nil else { return body }
        return [pre.map { "pre\(name): \($0)" }, "\(name): \(body)", post.map { "post\(name): \($0)" }]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    static func predictedPort(script: String, body: String, framework: Framework?) -> Int? {
        if let port = PortPrediction.explicitPort(in: body) { return port }
        if script == "preview", let framework, let port = previewPorts[framework.name] { return port }
        return PortPrediction.predict(script: nil, envFiles: [], framework: framework?.name)
    }
}
