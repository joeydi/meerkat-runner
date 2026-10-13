import Models
import Scanner
import XCTest

final class AddressClassifierTests: XCTestCase {
    func testIPv4() {
        XCTAssertEqual(AddressClassifier.classify(bytes: [127, 0, 0, 1], isIPv6: false), .loopback)
        XCTAssertEqual(AddressClassifier.classify(bytes: [127, 1, 2, 3], isIPv6: false), .loopback)
        XCTAssertEqual(AddressClassifier.classify(bytes: [0, 0, 0, 0], isIPv6: false), .wildcard)
        XCTAssertEqual(AddressClassifier.classify(bytes: [192, 168, 1, 5], isIPv6: false), .specific("192.168.1.5"))
    }

    func testIPv6() {
        let any = [UInt8](repeating: 0, count: 16)
        var loopback = any
        loopback[15] = 1
        var mapped = any
        mapped[10] = 0xff
        mapped[11] = 0xff
        mapped[12...15] = [127, 0, 0, 1]

        XCTAssertEqual(AddressClassifier.classify(bytes: any, isIPv6: true), .wildcard)
        XCTAssertEqual(AddressClassifier.classify(bytes: loopback, isIPv6: true), .loopback)
        XCTAssertEqual(AddressClassifier.classify(bytes: mapped, isIPv6: true), .loopback)
    }

    func testSystemListenerFilter() {
        let airplay = Listener(
            pid: 400, pgid: 400, ppid: 1, port: 5000, address: .wildcard, family: .v4,
            executablePath: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
            argv: [], cwd: nil, startTime: ProcessStartTime(seconds: 0, microseconds: 0)
        )
        XCTAssertTrue(SystemListeners.isSystemListener(airplay))
    }

    func testScanSkeleton() async throws {
        // TODO(v0.1): start a real listener (Scripts/test-servers) and assert it appears within one poll;
        // v4+v6 de-dup; wildcard vs loopback classification end-to-end.
        throw XCTSkip("PortScanner.scan() not implemented yet (v0.1)")
    }
}
