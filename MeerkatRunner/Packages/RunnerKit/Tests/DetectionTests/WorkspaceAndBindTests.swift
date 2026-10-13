import Detection
import Foundation
import Models
import XCTest

/// Workspace packages inside a monorepo, localhost-bind flags (AGENTS.md §6.6) and the static detector.
final class WorkspaceAndBindTests: XCTestCase {
    private var fixtures: URL { FixtureTests.fixturesURL }

    // MARK: - Workspace root

    func testWorkspacePackageUsesTheRootsPackageManager() async {
        let web = fixtures.appendingPathComponent("pnpm-monorepo/apps/web", isDirectory: true)
        let files = FileSnapshot.read(web)
        XCTAssertEqual(files.workspaceRoot?.relativePath, "../..")
        XCTAssertEqual(files.workspaceRoot?.lockfiles, ["pnpm-lock.yaml"])

        let manager = NodeDetector.packageManager(files: files, packageJSON: files.json("package.json"))
        XCTAssertEqual(manager.name, "pnpm")
        XCTAssertEqual(manager.lockfile, "../../pnpm-lock.yaml")

        let proposals = await DetectionEngine.detect(in: web)
        XCTAssertEqual(proposals.first?.command, .argv(["pnpm", "run", "dev"]))
        XCTAssertEqual(proposals.first?.framework, "Next.js 14")
    }

    func testMonorepoRootAndStandaloneProjectsHaveNoWorkspaceRoot() {
        XCTAssertNil(FileSnapshot.read(fixtures.appendingPathComponent("pnpm-monorepo")).workspaceRoot)
        XCTAssertNil(FileSnapshot.read(fixtures.appendingPathComponent("next-pnpm")).workspaceRoot)
    }

    func testLocalLockfileBeatsTheRoot() {
        let files = FileSnapshot(
            topLevel: ["package.json", "yarn.lock"], entries: [:],
            workspaceRoot: .init(relativePath: "..", lockfiles: ["pnpm-lock.yaml"])
        )
        XCTAssertEqual(NodeDetector.packageManager(files: files, packageJSON: [:]).name, "yarn")
        let rootOnly = FileSnapshot(
            topLevel: ["package.json"], entries: [:],
            workspaceRoot: .init(relativePath: "..", lockfiles: [], packageManager: "bun@1.1.0")
        )
        XCTAssertEqual(NodeDetector.packageManager(files: rootOnly, packageJSON: [:]).name, "bun")
    }

    // MARK: - Localhost bind

    private func node(_ argv: [String], script: String?, label: String = "pnpm dev", detector: DetectorID = .node) -> Proposal {
        Proposal(detector: detector, label: label, command: .argv(argv), resolvedScript: script, source: "package.json", confidence: 100)
    }

    func testNodeFrameworkFlags() {
        let address = LocalhostBinding.address
        XCTAssertEqual(
            LocalhostBinding.override(for: node(["pnpm", "run", "dev"], script: "next dev --turbopack"), port: 3000),
            BindOverride(arguments: ["-H", address])
        )
        XCTAssertEqual(
            LocalhostBinding.override(for: node(["yarn", "run", "dev"], script: "vite", label: "yarn dev"), port: nil),
            BindOverride(arguments: ["--host", address])
        )
        // npm passes script arguments only after `--`.
        XCTAssertEqual(
            LocalhostBinding.override(for: node(["npm", "run", "dev"], script: "astro dev", label: "npm dev"), port: nil),
            BindOverride(arguments: ["--", "--host", address])
        )
        XCTAssertEqual(
            LocalhostBinding.override(
                for: node(["pnpm", "--filter", "@acme/web", "run", "dev"], script: "next dev", label: "@acme/web dev", detector: .monorepo),
                port: nil
            ),
            BindOverride(arguments: ["-H", address])
        )
        // The script's own line is used when pre/post hooks are listed.
        XCTAssertEqual(
            LocalhostBinding.override(for: node(["npm", "run", "dev"], script: "predev: node setup.js\ndev: vite", label: "npm dev"), port: nil),
            BindOverride(arguments: ["--", "--host", address])
        )
    }

    func testChainedOrUnknownNodeScriptsGetHOST() {
        for script in ["next build && next start", "turbo dev", "node server.js", "vite | tee log", nil] {
            XCTAssertEqual(
                LocalhostBinding.override(for: node(["pnpm", "run", "dev"], script: script), port: nil),
                LocalhostBinding.generic,
                script ?? "nil"
            )
        }
        XCTAssertEqual(LocalhostBinding.override(for: node(["pnpm", "run", "dev"], script: "next lint"), port: nil), LocalhostBinding.generic)
    }

    func testOtherFrameworks() {
        func proposal(_ detector: DetectorID, _ argv: [String]) -> Proposal {
            Proposal(detector: detector, label: argv.joined(separator: " "), command: .argv(argv), source: "x", confidence: 1)
        }
        let address = LocalhostBinding.address
        XCTAssertEqual(
            LocalhostBinding.override(for: proposal(.django, ["python3", "manage.py", "runserver"]), port: 8001),
            BindOverride(arguments: ["\(address):8001"])
        )
        XCTAssertEqual(
            LocalhostBinding.override(for: proposal(.rails, ["bin/rails", "server"]), port: nil),
            BindOverride(arguments: ["-b", address])
        )
        XCTAssertEqual(
            LocalhostBinding.override(for: proposal(.rails, ["bin/dev"]), port: nil),
            BindOverride(environment: ["BINDING": address])
        )
        XCTAssertEqual(
            LocalhostBinding.override(for: proposal(.python, ["python3", "-m", "flask", "run"]), port: nil),
            BindOverride(arguments: ["--host", address])
        )
        XCTAssertEqual(
            LocalhostBinding.override(for: proposal(.laravel, ["php", "artisan", "serve"]), port: nil),
            BindOverride(arguments: ["--host=\(address)"])
        )
        XCTAssertNil(LocalhostBinding.override(for: proposal(.compose, ["docker", "compose", "up"]), port: nil))
        XCTAssertEqual(LocalhostBinding.override(for: proposal(.procfile, ["web"]), port: nil), LocalhostBinding.generic)
        XCTAssertEqual(LocalhostBinding.override(for: nil, port: nil), LocalhostBinding.generic)
        // The static server already binds 127.0.0.1.
        XCTAssertEqual(
            LocalhostBinding.override(for: proposal(.static, ["python3", "-m", "http.server", "8000", "--bind", address]), port: nil),
            BindOverride()
        )
    }

    func testLaunchCommandAppendsBindArguments() {
        var project = Project(name: "web", path: "/p", detector: .node, command: .argv(["pnpm", "run", "dev"]))
        project.localhostBind = BindOverride(arguments: ["-H", "127.0.0.1"], environment: ["HOST": "127.0.0.1"])
        // Off: nothing added, even with a saved override.
        XCTAssertEqual(project.launchCommand, .argv(["pnpm", "run", "dev"]))
        XCTAssertEqual(project.bindEnvironment, [:])
        project.preferLocalhostBind = true
        XCTAssertEqual(project.launchCommand, .argv(["pnpm", "run", "dev", "-H", "127.0.0.1"]))
        XCTAssertEqual(project.bindEnvironment, ["HOST": "127.0.0.1"])
        XCTAssertEqual(LaunchCommand.shell("make dev").appending(["--host", "it's"]), .shell("make dev '--host' 'it'\\''s'"))
    }

    // MARK: - Static

    func testStaticNeedsIndexHTMLAndNothingElse() {
        let detector = StaticDetector()
        let folder = URL(fileURLWithPath: "/tmp/site")
        XCTAssertEqual(detector.detect(in: folder, files: FileSnapshot(topLevel: ["index.html", "style.css"], entries: [:])).count, 1)
        XCTAssertEqual(detector.detect(in: folder, files: FileSnapshot(topLevel: ["index.html", "package.json"], entries: [:])).count, 0)
        XCTAssertEqual(detector.detect(in: folder, files: FileSnapshot(topLevel: ["index.html", "requirements.txt"], entries: [:])).count, 0)
        XCTAssertEqual(detector.detect(in: folder, files: FileSnapshot(topLevel: ["about.html"], entries: [:])).count, 0)
    }
}
