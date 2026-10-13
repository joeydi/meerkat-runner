import Detection
import Foundation
import Models
import XCTest

final class RunningProcessProposalTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Users/me/Sites/instarchive/site", isDirectory: true)

    func testUsesRunningArgvWithPathsInsideFolderMadeRelative() throws {
        let proposal = try XCTUnwrap(RunningProcessProposal.make(
            argv: ["/opt/homebrew/bin/node", "/Users/me/Sites/instarchive/site/server.js", "--port", "8000"],
            folder: folder, port: 8000, framework: "Node", rankedFirst: true
        ))
        XCTAssertEqual(proposal.command, .argv(["/opt/homebrew/bin/node", "./server.js", "--port", "8000"]))
        XCTAssertEqual(proposal.source, "running on :8000")
        XCTAssertEqual(proposal.predictedPort, 8000)
        XCTAssertEqual(proposal.framework, "Node")
    }

    func testLeavesOtherPathsAndSiblingFoldersAlone() throws {
        let proposal = try XCTUnwrap(RunningProcessProposal.make(
            argv: ["python3", "-m", "http.server", "8000", "--directory", "/Users/me/Sites/instarchive/site-old"],
            folder: folder, port: 8000, framework: "Python", rankedFirst: true
        ))
        XCTAssertEqual(
            proposal.command,
            .argv(["python3", "-m", "http.server", "8000", "--directory", "/Users/me/Sites/instarchive/site-old"])
        )
    }

    func testVersionPinnedExecutablesBecomeStableNames() throws {
        let homebrewPython = "/opt/homebrew/Cellar/python@3.13/3.13.0_1/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"
        let pythonOrg = "/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
        let cellarNode = "/opt/homebrew/Cellar/node/22.11.0/bin/node"

        func command(_ executable: String) throws -> LaunchCommand {
            try XCTUnwrap(RunningProcessProposal.make(
                argv: [executable, "-m", "http.server", "8000"], folder: folder, port: 8000, framework: nil, rankedFirst: true
            )).command
        }
        XCTAssertEqual(try command(homebrewPython), .argv(["python3.13", "-m", "http.server", "8000"]))
        XCTAssertEqual(try command(pythonOrg), .argv(["python3.12", "-m", "http.server", "8000"]))
        XCTAssertEqual(try command(cellarNode), .argv(["node", "-m", "http.server", "8000"]))
        // Stable paths are kept as they are.
        XCTAssertEqual(try command("/opt/homebrew/bin/python3"), .argv(["/opt/homebrew/bin/python3", "-m", "http.server", "8000"]))
        XCTAssertEqual(try command(".venv/bin/python"), .argv([".venv/bin/python", "-m", "http.server", "8000"]))
    }

    func testNoArgvNoProposal() {
        XCTAssertNil(RunningProcessProposal.make(argv: [], folder: folder, port: 8000, framework: nil, rankedFirst: true))
    }

    func testRanksBelowDetectorsUnlessAlone() throws {
        let alone = try XCTUnwrap(RunningProcessProposal.make(argv: ["node"], folder: folder, port: 1, framework: nil, rankedFirst: true))
        let behind = try XCTUnwrap(RunningProcessProposal.make(argv: ["node"], folder: folder, port: 1, framework: nil, rankedFirst: false))
        XCTAssertGreaterThan(alone.confidence, behind.confidence)
        XCTAssertLessThan(alone.confidence, 30) // below every detector (Compose is the lowest at 30)
    }
}
