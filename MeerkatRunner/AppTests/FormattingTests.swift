import Foundation
@testable import MeerkatRunner
import SwiftUI
import XCTest

final class FormattingTests: XCTestCase {
    func testUptime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Format.uptime(since: now.addingTimeInterval(-30), now: now), "0m")
        XCTAssertEqual(Format.uptime(since: now.addingTimeInterval(-6 * 60), now: now), "6m")
        XCTAssertEqual(Format.uptime(since: now.addingTimeInterval(-(2 * 3_600 + 14 * 60)), now: now), "2h 14m")
        XCTAssertEqual(Format.uptime(since: now.addingTimeInterval(-3 * 3_600), now: now), "3h")
        XCTAssertEqual(Format.uptime(since: now.addingTimeInterval(-3 * 86_400), now: now), "3d")
    }

    func testLocalURLAlwaysUsesLocalhost() {
        XCTAssertEqual(Format.localURL(port: 5173)?.absoluteString, "http://localhost:5173")
    }

    func testANSIStripsEscapesAndKeepsText() {
        let raw = "\u{1B}[32m✓\u{1B}[39m Ready in \u{1B}[1m298ms\u{1B}[22m\u{1B}]8;;https://x\u{07}"
        let rendered = String(ANSIText.attributed(raw).characters)
        XCTAssertEqual(rendered, "✓ Ready in 298ms")
    }

    func testANSIColoursRuns() {
        let attributed = ANSIText.attributed("\u{1B}[31mred\u{1B}[0m plain")
        let runs = attributed.runs.map { (String(attributed[$0.range].characters), $0.foregroundColor != nil) }
        XCTAssertEqual(runs.map(\.0), ["red", " plain"])
        XCTAssertEqual(runs.map(\.1), [true, false])
    }

    func testANSISkips256ColourArguments() {
        let rendered = String(ANSIText.attributed("\u{1B}[38;5;208morange\u{1B}[0m").characters)
        XCTAssertEqual(rendered, "orange")
    }
}
