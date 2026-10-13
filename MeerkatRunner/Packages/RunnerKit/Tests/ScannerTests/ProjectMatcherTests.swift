import Foundation
import Models
import Scanner
import XCTest

final class ProjectMatcherTests: XCTestCase {
    private func listener(cwd: String?, argv: [String] = ["node"], pgid: pid_t = 900) -> Listener {
        Listener(
            pid: 901, pgid: pgid, ppid: 1, port: 3000, address: .loopback, family: .v4,
            executablePath: "/usr/local/bin/node", argv: argv, cwd: cwd,
            startTime: ProcessStartTime(seconds: 1, microseconds: 0)
        )
    }

    private func project(_ path: String) -> Project {
        Project(name: (path as NSString).lastPathComponent, path: path, detector: .node, command: .argv(["npm", "run", "dev"]))
    }

    func testDeepestPathWins() {
        let root = project("/Users/me/mono")
        let web = project("/Users/me/mono/apps/web")
        let id = ProjectMatcher().match(listener(cwd: "/Users/me/mono/apps/web"), projects: [root, web])
        XCTAssertEqual(id, web.id)
    }

    func testSiblingPrefixDoesNotMatch() {
        let docs = project("/Users/me/docs")
        XCTAssertNil(ProjectMatcher().match(listener(cwd: "/Users/me/docs-old"), projects: [docs]))
    }

    func testLaunchedGroupWins() {
        let docs = project("/Users/me/docs")
        let other = project("/Users/me/other")
        let matcher = ProjectMatcher(launchedGroups: [900: other.id])
        XCTAssertEqual(matcher.match(listener(cwd: "/Users/me/docs"), projects: [docs, other]), other.id)
    }

    func testArgvAbsolutePath() {
        let docs = project("/Users/me/docs")
        let match = ProjectMatcher().match(listener(cwd: nil, argv: ["node", "/Users/me/docs/server.js"]), projects: [docs])
        XCTAssertEqual(match, docs.id)
    }
}
