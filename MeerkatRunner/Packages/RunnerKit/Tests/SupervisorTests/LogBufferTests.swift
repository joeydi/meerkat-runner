import Foundation
import Supervisor
import XCTest

final class LogBufferTests: XCTestCase {
    func testSplitsLinesAndHoldsPartials() {
        var buffer = LogBuffer(capacity: 10)
        buffer.append(Data("one\r\ntw".utf8))
        XCTAssertEqual(buffer.lines.map(\.raw), ["one"])
        buffer.append(Data("o\n".utf8))
        XCTAssertEqual(buffer.lines.map(\.raw), ["one", "two"])
    }

    func testRingDropsOldest() {
        var buffer = LogBuffer(capacity: 3)
        for index in 1...5 { buffer.append(Data("\(index)\n".utf8)) }
        XCTAssertEqual(buffer.lines.map(\.raw), ["3", "4", "5"])
    }

    func testStripsANSIForSearch() {
        var buffer = LogBuffer()
        buffer.append(Data("\u{1B}[32mready\u{1B}[0m in 300ms\n".utf8))
        XCTAssertEqual(buffer.lines.first?.plain, "ready in 300ms")
        XCTAssertTrue(buffer.lines.first?.raw.contains("\u{1B}[32m") ?? false)
    }
}
