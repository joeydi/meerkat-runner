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

    struct Expected: Decodable {
        struct Item: Decodable {
            var label: String
            var argv: [String]?
            var shell: String?
            var resolvedScript: String?
            var source: String
            var predictedPort: Int?
        }

        var proposals: [Item]
    }

    func testFixturesDirectoryExists() {
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.fixturesURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testAllFixtures() async throws {
        throw XCTSkip("Detectors are stubs until v0.2")
        // Kept for when detectors land:
        // for each fixture folder with expected.json:
        //   let proposals = await DetectionEngine.detect(in: folder)
        //   compare label/command/resolvedScript/source/predictedPort in order.
    }

    func testFileSnapshotEnforcesSizeCap() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = Data(repeating: UInt8(ascii: " "), count: FileSnapshot.maxFileSize + 1)
        try big.write(to: folder.appendingPathComponent("package.json"))
        let snapshot = FileSnapshot.read(folder)
        XCTAssertEqual(snapshot.entries["package.json"], .tooLarge)
        XCTAssertNil(snapshot.data("package.json"))
    }

    func testPortPrediction() {
        XCTAssertEqual(PortPrediction.explicitPort(in: "next dev --port 4000"), 4000)
        XCTAssertEqual(PortPrediction.explicitPort(in: "vite --port=5174"), 5174)
        XCTAssertEqual(PortPrediction.explicitPort(in: "astro dev -p 4322"), 4322)
        XCTAssertEqual(PortPrediction.envPort(in: "API_KEY=secret\nexport PORT=\"8080\"\n"), 8080)
        XCTAssertEqual(PortPrediction.predict(script: "next dev", envFiles: [], framework: "Next.js"), 3000)
        XCTAssertTrue(PortPrediction.systemConflicts.contains(PortPrediction.frameworkDefaults["Flask"]!))
    }
}
