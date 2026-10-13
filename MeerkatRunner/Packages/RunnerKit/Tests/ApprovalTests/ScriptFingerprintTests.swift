import Approval
import Foundation
import Models
import XCTest

final class ScriptFingerprintTests: XCTestCase {
    private let base = ScriptFingerprint.Input(
        projectPath: "/Users/me/docs",
        command: .argv(["pnpm", "run", "dev"]),
        resolvedScript: "next dev --turbopack",
        envFileNames: [".env.local"],
        envOverrideKeys: ["API_URL"],
        wrapper: []
    )

    private func fingerprint(_ change: (inout ScriptFingerprint.Input) -> Void) -> String {
        var input = base
        change(&input)
        return ScriptFingerprint.compute(input)
    }

    func testIsStableHexSHA256() {
        let value = ScriptFingerprint.compute(base)
        XCTAssertEqual(value.count, 64)
        XCTAssertEqual(value, ScriptFingerprint.compute(base))
    }

    func testChangesWhenWhatRunsChanges() {
        let original = ScriptFingerprint.compute(base)
        XCTAssertNotEqual(original, fingerprint { $0.resolvedScript = "next dev" })
        XCTAssertNotEqual(original, fingerprint { $0.resolvedScript = "predev: node scripts/setup.js\nnext dev --turbopack" })
        XCTAssertNotEqual(original, fingerprint { $0.command = .argv(["pnpm", "run", "start"]) })
        XCTAssertNotEqual(original, fingerprint { $0.command = .shell("pnpm run dev") })
        XCTAssertNotEqual(original, fingerprint { $0.envFileNames = [".env"] })
        XCTAssertNotEqual(original, fingerprint { $0.envOverrideKeys = ["API_URL", "NODE_OPTIONS"] })
        XCTAssertNotEqual(original, fingerprint { $0.wrapper = ["mise", "exec", "--"] })
        XCTAssertNotEqual(original, fingerprint { $0.projectPath = "/Users/me/docs2" })
        XCTAssertNotEqual(original, fingerprint { $0.sourceMaterial = Data("services: {}".utf8) })
    }

    func testIgnoresEnvValuesAndNameOrder() {
        var project = Project(
            name: "docs", path: "/Users/me/docs", detector: .node, command: .argv(["pnpm", "run", "dev"]),
            envOverrides: ["A": "1", "B": "2"], envFiles: [".env.local"]
        )
        let first = ScriptFingerprint.compute(.init(project: project, resolvedScript: "next dev"))
        project.envOverrides = ["B": "changed", "A": "also changed"]
        let second = ScriptFingerprint.compute(.init(project: project, resolvedScript: "next dev"))
        XCTAssertEqual(first, second)
    }

    func testArgvBoundariesMatter() {
        let joined = fingerprint { $0.command = .argv(["pnpm", "run dev"]) }
        let split = fingerprint { $0.command = .argv(["pnpm", "run", "dev"]) }
        XCTAssertNotEqual(joined, split)
    }
}
