import Models
import XCTest

final class ListenerGroupTests: XCTestCase {
    private func listener(pid: pid_t, port: Int, family: AddressFamily, address: ListenAddress = .loopback) -> Listener {
        Listener(
            pid: pid, pgid: pid, ppid: 1, port: port, address: address, family: family,
            executablePath: "/usr/local/bin/node", argv: ["node"], cwd: nil,
            startTime: ProcessStartTime(seconds: 1, microseconds: 0)
        )
    }

    func testGroupsByProcessAndPort() {
        let groups = ListenerGroup.group([
            listener(pid: 20, port: 5173, family: .v6),
            listener(pid: 10, port: 3000, family: .v6, address: .wildcard),
            listener(pid: 10, port: 3000, family: .v4),
            listener(pid: 30, port: 3000, family: .v4),
        ])
        XCTAssertEqual(groups.map(\.id), ["10:3000", "30:3000", "20:5173"])
        XCTAssertEqual(groups[0].listeners.map(\.family), [.v4, .v6])
        XCTAssertTrue(groups[0].isLANVisible)
        XCTAssertFalse(groups[1].isLANVisible)
    }

    func testRejectsMixedGroups() {
        XCTAssertNil(ListenerGroup([]))
        XCTAssertNil(ListenerGroup([listener(pid: 1, port: 80, family: .v4), listener(pid: 2, port: 80, family: .v4)]))
    }
}
