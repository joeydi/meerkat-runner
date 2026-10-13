import Foundation
import Models
@testable import Registry
import XCTest

final class ServerRegistryTests: XCTestCase {
    private func listener(
        pid: pid_t, port: Int, family: AddressFamily = .v4, address: ListenAddress = .loopback,
        path: String = "/usr/local/bin/node", cwd: String? = nil
    ) -> Listener {
        Listener(
            pid: pid, pgid: pid, ppid: 1, port: port, address: address, family: family,
            executablePath: path, argv: [path], cwd: cwd,
            startTime: ProcessStartTime(seconds: 1_700_000_000, microseconds: 0)
        )
    }

    @MainActor
    func testUnmatchedListenersBecomeGroupedOtherListeners() {
        let registry = ServerRegistry()
        registry.apply([
            listener(pid: 10, port: 3000),
            listener(pid: 10, port: 3000, family: .v6),
            listener(
                pid: 20, port: 5000, address: .wildcard,
                path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
            ),
        ])

        XCTAssertEqual(registry.otherListeners.map(\.port), [3000, 5000])
        XCTAssertEqual(registry.otherListeners.first?.listeners.count, 2)

        // System listeners are hidden by default (AirPlay Receiver on 5000).
        XCTAssertEqual(registry.visibleOtherListeners.map(\.port), [3000])
        registry.hideSystemListeners = false
        XCTAssertEqual(registry.visibleOtherListeners.map(\.port), [3000, 5000])
    }

    @MainActor
    func testListenerDisappearsOnNextScan() {
        let registry = ServerRegistry()
        registry.apply([listener(pid: 10, port: 3000)])
        XCTAssertEqual(registry.otherListeners.count, 1)
        registry.apply([])
        XCTAssertTrue(registry.otherListeners.isEmpty)
        XCTAssertEqual(registry.runningCount, 0)
    }
}
