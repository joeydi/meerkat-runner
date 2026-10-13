import XCTest

/// Integration tests against real processes from `Scripts/test-servers/` (AGENTS.md §10).
final class SupervisorIntegrationTests: XCTestCase {
    func testStartLearnsPortWithinFiveSeconds() throws { throw XCTSkip("TODO(v0.2)") }
    func testStopKillsChildWorker() throws { throw XCTSkip("TODO(v0.2)") }
    func testSIGTERMIgnoringServerIsKilledAfterFiveSeconds() throws { throw XCTSkip("TODO(v0.2)") }
    func testPIDReuseGuardAbortsOnChangedStartTime() throws { throw XCTSkip("TODO(v0.2)") }
    func testStoppingTerminalStartedServerLeavesShellAlive() throws { throw XCTSkip("TODO(v0.2)") }
    func testRestartInRunnerFreesPortThenRestarts() throws { throw XCTSkip("TODO(v0.2)") }
}
