import Foundation
@testable import Registry
import XCTest

/// Health URLs (AGENTS.md §6.4): loopback only, 2xx–4xx count as up.
final class HealthCheckTests: XCTestCase {
    func testOnlyLoopbackURLsAreAllowed() {
        for text in ["http://localhost:3000/health", "https://127.0.0.1:8443/", "http://[::1]:5173", "HTTP://LOCALHOST:3000"] {
            XCTAssertNotNil(HealthCheck.parse(text), text)
        }
        for text in ["", "  ", "http://example.com/health", "http://192.168.1.5:3000", "file:///etc/passwd", "localhost:3000", "ftp://localhost/"] {
            XCTAssertNil(HealthCheck.parse(text), text)
        }
    }

    func testStatusesThatCountAsUp() {
        XCTAssertTrue(HealthCheck.isUp(status: 200))
        XCTAssertTrue(HealthCheck.isUp(status: 302))
        XCTAssertTrue(HealthCheck.isUp(status: 404))
        XCTAssertFalse(HealthCheck.isUp(status: 500))
        XCTAssertFalse(HealthCheck.isUp(status: 503))
    }

    func testProbeRefusesNonLoopbackWithoutARequest() async {
        let result = await HealthCheck.probe(URL(string: "http://example.com/")!)
        XCTAssertFalse(result)
    }

    func testProbeOfAClosedPortFails() async {
        // Port 9 (discard) is essentially never open on a dev Mac or CI runner.
        let result = await HealthCheck.probe(URL(string: "http://127.0.0.1:9/")!)
        XCTAssertFalse(result)
    }
}
