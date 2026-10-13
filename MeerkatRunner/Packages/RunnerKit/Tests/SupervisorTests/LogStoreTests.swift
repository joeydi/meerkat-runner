import Foundation
@testable import Supervisor
import XCTest

final class LogStoreTests: XCTestCase {
    func testDetectsLocalURLPortOnce() {
        final class Ports: @unchecked Sendable { var values: [Int] = [] }
        let ports = Ports()
        let store = LogStore(fileURL: nil) { ports.values.append($0) }
        store.append(Data("  \u{1B}[32m➜\u{1B}[39m  Local:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m\n".utf8))
        store.append(Data("ready on http://127.0.0.1:9999\n".utf8))
        XCTAssertEqual(ports.values, [5173])
    }

    func testPortPatterns() {
        XCTAssertEqual(LogStore.port(in: "Serving at http://localhost:8000/"), 8000)
        XCTAssertEqual(LogStore.port(in: "  - Local: http://[::1]:4321"), 4321)
        XCTAssertEqual(LogStore.port(in: "Listening on http://0.0.0.0:3000"), 3000)
        XCTAssertNil(LogStore.port(in: "https://example.com:443"))
    }

    func testRotatesAtFiveMegabytesKeepingThree() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rotate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("p.log")
        let store = LogStore(fileURL: url)
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 1_024 * 1_024) + Data("\n".utf8)
        for _ in 0..<16 { store.append(chunk) } // ~16 MB → three rotations

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["p.log", "p.log.1", "p.log.2"])
    }

    func testResumeLoadsTailOfExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("p.log")
        try Data("line one\nline two\n".utf8).write(to: url)
        let store = LogStore(fileURL: url, resume: true)
        XCTAssertEqual(store.snapshot().lines.map(\.raw), ["line one", "line two"])
    }
}
