import Darwin
import Foundation
import Models
import ProcInfo
// Tests are the one other place allowed to call spawn directly (AGENTS.md §8.1 rule 2).
@_spi(ApprovalGate) @testable import Supervisor
import XCTest

/// Integration tests against real processes from `Scripts/test-servers/` (AGENTS.md §10).
final class SupervisorIntegrationTests: XCTestCase {
    static let testServers = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SupervisorTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // RunnerKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // MeerkatRunner
        .appendingPathComponent("Scripts/test-servers", isDirectory: true)

    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        if env["PATH"] == nil { env["PATH"] = ShellEnv.fallbackPATH }
        return env
    }

    private func spec(_ argv: [String], projectID: UUID = UUID()) -> LaunchSpec {
        LaunchSpec(
            projectID: projectID, command: .argv(argv),
            workingDirectory: Self.testServers.path, environment: environment
        )
    }

    private func requireExecutable(_ name: String) throws {
        if ExecutableResolver.find(name, path: environment["PATH"]) == nil {
            throw XCTSkip("\(name) is not installed")
        }
    }

    /// Polls `condition` every 50 ms until true or the timeout passes.
    private func eventually(
        timeout: Duration = .seconds(5), _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    private func output(_ supervisor: ProcessSupervisor, _ id: UUID) async -> String {
        await supervisor.log(for: id)?.snapshot().lines.map(\.plain).joined(separator: "\n") ?? ""
    }

    /// Collects events in the background.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ProcessSupervisor.Event] = []
        func append(_ event: ProcessSupervisor.Event) { lock.lock(); events.append(event); lock.unlock() }
        var all: [ProcessSupervisor.Event] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func record(_ supervisor: ProcessSupervisor) -> EventLog {
        let log = EventLog()
        Task { for await event in supervisor.events { log.append(event) } }
        return log
    }

    // MARK: -

    func testStartLearnsPortFromOutputWithinFiveSeconds() async throws {
        try requireExecutable("python3")
        let supervisor = ProcessSupervisor()
        let events = record(supervisor)
        let id = UUID()
        let launched = try await supervisor.spawn(spec(["python3", "http_server.py", "0"], projectID: id))
        XCTAssertEqual(launched.pgid, launched.identity.pid, "POSIX_SPAWN_SETSID: own process group")
        XCTAssertGreaterThan(launched.identity.startTime.seconds, 0)

        let sawPort = await eventually {
            events.all.contains { if case .portInOutput(id, let port) = $0 { return port > 0 }; return false }
        }
        let soFar = await output(supervisor, id)
        XCTAssertTrue(sawPort, "output so far:\n\(soFar)")

        try await supervisor.stop(projectID: id)
        let exited = await eventually { events.all.contains(.exited(projectID: id, exitCode: 143, requested: true)) }
        XCTAssertTrue(exited, "events: \(events.all)")
        // Output stays readable after exit (crashed servers' logs).
        let afterExit = await output(supervisor, id)
        XCTAssertTrue(afterExit.contains("Serving at"), afterExit)
        let stillManaged = await supervisor.isManaged(id)
        XCTAssertFalse(stillManaged)
    }

    func testOutputIsATerminal() async throws {
        let supervisor = ProcessSupervisor()
        let id = UUID()
        _ = try await supervisor.spawn(spec(["/bin/sh", "-c", "test -t 1 && echo IS_TTY; stty size; sleep 5"], projectID: id))
        let ok = await eventually { await output(supervisor, id).contains("IS_TTY") }
        let text = await output(supervisor, id)
        XCTAssertTrue(ok, text)
        XCTAssertTrue(text.contains("40 120"), text)
        try await supervisor.stop(projectID: id)
    }

    func testStopKillsChildWorkerToo() async throws {
        try requireExecutable("node")
        let supervisor = ProcessSupervisor()
        let id = UUID()
        _ = try await supervisor.spawn(spec(["node", "node_with_worker.js", "0"], projectID: id))

        var workerPID: pid_t?
        _ = await eventually {
            let text = await output(supervisor, id)
            if let range = text.range(of: #"worker pid (\d+)"#, options: .regularExpression) {
                workerPID = pid_t(text[range].split(separator: " ").last ?? "")
            }
            return workerPID != nil && text.contains("Listening on")
        }
        let workerOutput = await output(supervisor, id)
        let worker = try XCTUnwrap(workerPID, workerOutput)
        XCTAssertTrue(isAlive(worker))

        try await supervisor.stop(projectID: id)
        let workerGone = await eventually(timeout: .seconds(2)) { !isAlive(worker) }
        XCTAssertTrue(workerGone, "worker \(worker) survived stop")
    }

    func testServerIgnoringSIGTERMIsKilledAfterGracePeriod() async throws {
        try requireExecutable("python3")
        let supervisor = ProcessSupervisor()
        let events = record(supervisor)
        let id = UUID()
        let launched = try await supervisor.spawn(spec(["python3", "ignore_sigterm.py", "0"], projectID: id))
        let listening = await eventually { await output(supervisor, id).contains("ignoring SIGTERM") }
        XCTAssertTrue(listening)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure { try await supervisor.stop(projectID: id) }
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(4.5))
        XCTAssertLessThan(elapsed, .seconds(7))
        let killed = await eventually { events.all.contains(.exited(projectID: id, exitCode: 128 + SIGKILL, requested: true)) }
        XCTAssertTrue(killed, "events: \(events.all)")
        XCTAssertFalse(isAlive(launched.identity.pid))
    }

    func testPIDReuseGuardRefusesToSignal() async throws {
        let supervisor = ProcessSupervisor()
        let id = UUID()
        let launched = try await supervisor.spawn(spec(["/bin/sleep", "30"], projectID: id))
        var forged = launched.identity
        forged.startTime = ProcessStartTime(seconds: forged.startTime.seconds - 60, microseconds: 0)
        await supervisor.overrideIdentityForTesting(projectID: id, identity: forged)

        do {
            try await supervisor.stop(projectID: id)
            XCTFail("expected identityMismatch")
        } catch {
            XCTAssertEqual(error, .identityMismatch)
        }
        XCTAssertTrue(isAlive(launched.identity.pid), "nothing may be signalled on a mismatch")

        await supervisor.overrideIdentityForTesting(projectID: id, identity: launched.identity)
        try await supervisor.stop(projectID: id)
    }

    func testMissingExecutableFailsWithoutSpawning() async {
        let supervisor = ProcessSupervisor()
        do {
            _ = try await supervisor.spawn(spec(["definitely-not-a-real-command-meerkat"]))
            XCTFail("expected executableNotFound")
        } catch {
            XCTAssertEqual(error, .executableNotFound("definitely-not-a-real-command-meerkat"))
        }
        let records = await supervisor.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testRelaunchReadoptsRunningServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("readopt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = directory.appendingPathComponent("runtime.json")
        let id = UUID()

        let first = ProcessSupervisor(logsDirectory: directory, runtimeFile: runtime)
        let launched = try await first.spawn(spec(["/bin/sleep", "30"], projectID: id))

        // A second supervisor (the relaunched app) adopts it from runtime.json.
        let second = ProcessSupervisor(logsDirectory: directory, runtimeFile: runtime)
        let adopted = await second.readopt(knownProjects: [id])
        XCTAssertEqual(adopted, [id])
        let adoptedPGID = await second.snapshot()[id]?.pgid
        XCTAssertEqual(adoptedPGID, launched.pgid)

        // Unknown projects and dead processes are dropped.
        let third = ProcessSupervisor(logsDirectory: directory, runtimeFile: runtime)
        let none = await third.readopt(knownProjects: [])
        XCTAssertEqual(none, [])

        try await second.stop(projectID: id)
        let gone = await eventually { !isAlive(launched.identity.pid) || (try? ProcessInfoReader.bsdInfo(pid: launched.identity.pid)) == nil }
        XCTAssertTrue(gone)
    }

    func testRuntimeAndLogFilesArePrivate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("private-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = directory.appendingPathComponent("Support/runtime.json")
        let supervisor = ProcessSupervisor(logsDirectory: directory.appendingPathComponent("Logs"), runtimeFile: runtime)
        let id = UUID()
        _ = try await supervisor.spawn(spec(["/bin/sh", "-c", "echo hello; sleep 5"], projectID: id))
        _ = await eventually { await output(supervisor, id).contains("hello") }

        func mode(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        XCTAssertEqual(try mode(runtime), 0o600)
        XCTAssertEqual(try mode(directory.appendingPathComponent("Logs/\(id.uuidString).log")), 0o600)
        try await supervisor.stop(projectID: id)
    }

    // MARK: - Servers started elsewhere (§6.5)

    /// The first member of `pgid` whose name looks like Python, as a Listener on `port`.
    private func pythonListener(inGroup pgid: pid_t, port: Int) -> Listener? {
        let members = (try? ProcessInfoReader.processGroupMembers(pgid)) ?? []
        for pid in members {
            guard let info = try? ProcessInfoReader.bsdInfo(pid: pid), info.name.lowercased().hasPrefix("python") else { continue }
            return Listener(
                pid: pid, pgid: info.pgid, ppid: info.ppid, port: port, address: .loopback, family: .v4,
                executablePath: (try? ProcessInfoReader.executablePath(pid: pid)) ?? "",
                argv: [], cwd: nil,
                startTime: ProcessStartTime(seconds: info.startSeconds, microseconds: info.startMicroseconds)
            )
        }
        return nil
    }

    private func port(in text: String) -> Int? {
        guard let range = text.range(of: #"localhost:(\d+)"#, options: .regularExpression) else { return nil }
        return Int(text[range].split(separator: ":").last ?? "")
    }

    func testStoppingServerThatSharesAShellsGroupLeavesTheShellAlive() async throws {
        try requireExecutable("python3")
        let supervisor = ProcessSupervisor()
        let id = UUID()
        // Like a shell without job control: the server shares the shell's process group.
        let shell = try await supervisor.spawn(spec(
            ["/bin/sh", "-c", "python3 http_server.py 0 & while true; do sleep 1; done"], projectID: id
        ))
        var listener: Listener?
        _ = await eventually {
            if let port = port(in: await output(supervisor, id)) {
                listener = pythonListener(inGroup: shell.pgid, port: port)
            }
            return listener != nil
        }
        let server = try XCTUnwrap(listener)
        XCTAssertEqual(server.pgid, shell.pgid)

        // The shell is in the group, so only the server (and its descendants) may be targeted.
        let targets = try ProcessSupervisor.externalTargets(for: server)
        XCTAssertFalse(targets.contains { $0.pid == shell.identity.pid }, "must never target the shell")
        XCTAssertEqual(targets.last?.pid, server.pid)

        try await supervisor.stopExternal(server)
        let serverGone = await eventually(timeout: .seconds(2)) { !isAlive(server.pid) }
        XCTAssertTrue(serverGone)
        XCTAssertTrue(isAlive(shell.identity.pid), "the shell must survive")

        try await supervisor.stop(projectID: id)
    }

    func testStoppingServerInItsOwnGroupTargetsTheGroup() async throws {
        try requireExecutable("node")
        let supervisor = ProcessSupervisor()
        let id = UUID()
        let launched = try await supervisor.spawn(spec(["node", "node_with_worker.js", "0"], projectID: id))
        var workerPID: pid_t?
        var serverPort: Int?
        _ = await eventually {
            let text = await output(supervisor, id)
            if let range = text.range(of: #"worker pid (\d+)"#, options: .regularExpression) {
                workerPID = pid_t(text[range].split(separator: " ").last ?? "")
            }
            serverPort = port(in: text)
            return workerPID != nil && serverPort != nil
        }
        let worker = try XCTUnwrap(workerPID)
        let info = try XCTUnwrap(try? ProcessInfoReader.bsdInfo(pid: launched.identity.pid))
        let server = Listener(
            pid: launched.identity.pid, pgid: info.pgid, ppid: info.ppid, port: try XCTUnwrap(serverPort),
            address: .loopback, family: .v4, executablePath: launched.identity.executablePath, argv: [], cwd: nil,
            startTime: launched.identity.startTime
        )

        // Its own group, no shell in it, and not the parent's group: the whole group is the target.
        let targets = try ProcessSupervisor.externalTargets(for: server)
        XCTAssertEqual(Set(targets.map(\.pid)), [launched.identity.pid, worker])
        XCTAssertEqual(targets.last?.pid, launched.identity.pid, "leader last")

        try await supervisor.stopExternal(server)
        let allGone = await eventually(timeout: .seconds(2)) { !isAlive(worker) && !isAlive(launched.identity.pid) }
        XCTAssertTrue(allGone)
    }

    func testExternalStopRefusesChangedProcess() async throws {
        let supervisor = ProcessSupervisor()
        let id = UUID()
        let launched = try await supervisor.spawn(spec(["/bin/sleep", "30"], projectID: id))
        let stale = Listener(
            pid: launched.identity.pid, pgid: launched.pgid, ppid: getpid(), port: 1, address: .loopback, family: .v4,
            executablePath: launched.identity.executablePath, argv: [], cwd: nil,
            startTime: ProcessStartTime(seconds: launched.identity.startTime.seconds - 60, microseconds: 0)
        )
        do {
            try await supervisor.stopExternal(stale)
            XCTFail("expected identityMismatch")
        } catch {
            XCTAssertEqual(error, .identityMismatch)
        }
        XCTAssertTrue(isAlive(launched.identity.pid))
        try await supervisor.stop(projectID: id)
    }
}
