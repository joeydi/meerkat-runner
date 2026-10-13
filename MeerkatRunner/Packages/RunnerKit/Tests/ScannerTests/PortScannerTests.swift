import Darwin
import Models
import ProcInfo
import Scanner
import XCTest

/// Real libproc scans against sockets this test process opens (AGENTS.md §10 "Scanner").
final class PortScannerTests: XCTestCase {
    private func ours(_ listeners: [Listener], port: Int) -> [Listener] {
        listeners.filter { $0.pid == getpid() && $0.port == port }
    }

    func testListenerAppearsAndDisappearsWithinOnePoll() async throws {
        let scanner = PortScanner()
        let socket = try TestSocket.listen(v6: false)

        let found = ours(await scanner.scan(), port: socket.port)
        XCTAssertEqual(found.count, 1)
        let listener = try XCTUnwrap(found.first)
        XCTAssertEqual(listener.address, .loopback)
        XCTAssertEqual(listener.family, .v4)
        XCTAssertFalse(listener.isLANVisible)
        XCTAssertFalse(listener.executablePath.isEmpty)
        XCTAssertFalse(listener.argv.isEmpty)
        XCTAssertNotNil(listener.cwd)
        XCTAssertEqual(listener.pgid, getpgrp())
        XCTAssertGreaterThan(listener.startTime.seconds, 0)

        socket.close()
        XCTAssertTrue(ours(await scanner.scan(), port: socket.port).isEmpty)
    }

    func testV4AndV6OnSamePortGroupIntoOneRow() async throws {
        // The kernel picks a v4 port; the matching ::1 port is almost always free. Retry if not.
        var pair: (TestSocket, TestSocket)?
        for _ in 0..<5 where pair == nil {
            let v4 = try TestSocket.listen(v6: false)
            if let v6 = try? TestSocket.listen(v6: true, port: v4.port) {
                pair = (v4, v6)
            }
        }
        let (v4, v6) = try XCTUnwrap(pair)
        defer {
            v4.close()
            v6.close()
        }

        let listeners = ours(await PortScanner().scan(), port: v4.port)
        XCTAssertEqual(Set(listeners.map(\.family)), [.v4, .v6])

        let groups = ListenerGroup.group(listeners)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.listeners.map(\.family), [.v4, .v6])
        XCTAssertEqual(groups.first?.isLANVisible, false)
    }

    func testOnlyCurrentUsersProcesses() async {
        let listeners = await PortScanner().scan()
        for listener in listeners {
            // Every PID we report must still be ours (or have exited since the scan).
            if let info = try? ProcessInfoReader.bsdInfo(pid: listener.pid) {
                XCTAssertEqual(info.uid, getuid(), "pid \(listener.pid)")
            }
        }
    }

    func testScanIsCheap() async {
        // Rough guard for the "< 1% CPU with the menu closed" goal: a scan every 15 s must stay far
        // below 150 ms. Typical scans take a few milliseconds.
        let scanner = PortScanner()
        _ = await scanner.scan() // warm the metadata cache
        let clock = ContinuousClock()
        let elapsed = await clock.measure { _ = await scanner.scan() }
        XCTAssertLessThan(elapsed, .milliseconds(150))
    }
}
