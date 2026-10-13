import Foundation
import Models
@testable import Registry
import XCTest

final class ServerRegistryTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "RegistryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

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
        let registry = ServerRegistry(defaults: defaults)
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

        // AirPlay Receiver on 5000 is hidden by default. ControlCenter is both a system listener and
        // inside a .app, so either setting hides it; it shows only with both off.
        XCTAssertEqual(registry.visibleOtherListeners.map(\.port), [3000])
        registry.hideSystemListeners = false
        XCTAssertEqual(registry.visibleOtherListeners.map(\.port), [3000])
        registry.hideSystemListeners = true
        registry.hideAppListeners = false
        XCTAssertEqual(registry.visibleOtherListeners.map(\.port), [3000])
        registry.hideSystemListeners = false
        XCTAssertEqual(registry.visibleOtherListeners.map(\.port), [3000, 5000])
    }

    @MainActor
    func testListenerDisappearsOnNextScan() {
        let registry = ServerRegistry(defaults: defaults)
        registry.apply([listener(pid: 10, port: 3000)])
        XCTAssertEqual(registry.otherListeners.count, 1)
        registry.apply([])
        XCTAssertTrue(registry.otherListeners.isEmpty)
        XCTAssertEqual(registry.runningCount, 0)
    }
}

extension ServerRegistryTests {
    @MainActor
    func testAppListenersHiddenByDefaultAndSettingPersists() {
        let registry = ServerRegistry(defaults: defaults)
        registry.apply([
            listener(pid: 10, port: 8000, path: "/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"),
            listener(pid: 20, port: 17500, address: .wildcard, path: "/Applications/Dropbox.app/Contents/MacOS/Dropbox"),
        ])
        XCTAssertEqual(registry.visibleOtherListeners.map(\.port), [8000])

        registry.hideAppListeners = false
        XCTAssertEqual(registry.visibleOtherListeners.map(\.port), [8000, 17500])

        // A new registry on the same defaults remembers the choice.
        let relaunched = ServerRegistry(defaults: defaults)
        XCTAssertFalse(relaunched.hideAppListeners)
        XCTAssertTrue(relaunched.hideSystemListeners)
    }
}
