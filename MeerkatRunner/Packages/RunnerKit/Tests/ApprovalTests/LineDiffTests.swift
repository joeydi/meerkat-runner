import Approval
import XCTest

final class LineDiffTests: XCTestCase {
    func testMarksRemovedAndAddedLines() {
        let diff = LineDiff.diff(
            old: ["$ npm run dev", "predev: node scripts/setup.js", "dev: next dev"],
            new: ["$ npm run dev", "dev: next dev --turbopack"]
        )
        XCTAssertEqual(diff, [
            .same("$ npm run dev"),
            .removed("predev: node scripts/setup.js"),
            .removed("dev: next dev"),
            .added("dev: next dev --turbopack"),
        ])
    }

    func testIdenticalAndEmpty() {
        XCTAssertEqual(LineDiff.diff(old: ["a"], new: ["a"]), [.same("a")])
        XCTAssertEqual(LineDiff.diff(old: [], new: ["a"]), [.added("a")])
        XCTAssertEqual(LineDiff.diff(old: ["a"], new: []), [.removed("a")])
        XCTAssertEqual(LineDiff.diff(old: [], new: []), [])
    }

    func testApprovalLines() {
        XCTAssertEqual(LineDiff.approvalLines(command: "npm run dev", resolvedScript: "a\nb"), ["$ npm run dev", "a", "b"])
        XCTAssertEqual(LineDiff.approvalLines(command: "bin/dev", resolvedScript: nil), ["$ bin/dev"])
    }
}
