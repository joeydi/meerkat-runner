import CSpawn
import Darwin
import Foundation
import Models
import ProcInfo

public enum SupervisorError: Error, Sendable, Equatable {
    case executableNotFound(String)
    case spawnFailed(errno: Int32)
    case ptyFailed(errno: Int32)
    case alreadyRunning
    /// PID + start time + executable path no longer match the record (PID reuse). Nothing was signalled.
    case identityMismatch
    /// The target is a shell, terminal app, launchd, or another user's process.
    case forbiddenTarget
    case portStillInUse(Int)
    case notImplemented
}

/// What the approval gate hands the supervisor once a fingerprint has been verified.
public struct LaunchSpec: Sendable {
    public var projectID: UUID
    public var command: LaunchCommand
    /// Canonical project path; becomes the child's cwd.
    public var workingDirectory: String
    /// Final environment (captured env + env files + overrides + FORCE_COLOR=1). Never logged.
    public var environment: [String: String]
    /// Version-manager prefix, e.g. `["mise", "exec", "--"]`.
    public var wrapper: [String]

    public init(
        projectID: UUID,
        command: LaunchCommand,
        workingDirectory: String,
        environment: [String: String],
        wrapper: [String] = []
    ) {
        self.projectID = projectID
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.wrapper = wrapper
    }
}

/// Identity of a process Runner may signal. Re-verified immediately before every signal (§6.5).
public struct ProcessIdentity: Codable, Sendable, Hashable {
    public var pid: pid_t
    public var startTime: ProcessStartTime
    public var executablePath: String

    public init(pid: pid_t, startTime: ProcessStartTime, executablePath: String) {
        self.pid = pid
        self.startTime = startTime
        self.executablePath = executablePath
    }
}

/// A server Runner launched. Persisted to `runtime.json` for re-adoption after relaunch (§6.7).
public struct LaunchRecord: Codable, Sendable, Hashable {
    public var projectID: UUID
    public var identity: ProcessIdentity
    /// Equals the child PID because of `POSIX_SPAWN_SETSID`.
    public var pgid: pid_t
    public var startedAt: Date

    public init(projectID: UUID, identity: ProcessIdentity, pgid: pid_t, startedAt: Date = .now) {
        self.projectID = projectID
        self.identity = identity
        self.pgid = pgid
        self.startedAt = startedAt
    }
}

/// Spawns, tracks, and stops dev servers (AGENTS.md §6).
public actor ProcessSupervisor {
    public static let stopGracePeriod: Duration = .seconds(5)
    public static let portFreeTimeout: Duration = .seconds(10)
    static let ptyColumns: UInt16 = 120
    static let ptyRows: UInt16 = 40

    public enum Event: Sendable, Equatable {
        /// The server's process exited. `exitCode` is nil for a re-adopted (non-child) process.
        /// `requested` is true when Runner stopped it.
        case exited(projectID: UUID, exitCode: Int32?, requested: Bool)
        /// First local URL port printed by the server (§6.4, second signal).
        case portInOutput(projectID: UUID, port: Int)
    }

    /// Exits and output-detected ports, for the registry.
    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let logsDirectory: URL?
    private let runtimeFile: URL?
    private let logger = RunnerLog.logger(category: "supervisor")
    private let ioQueue = DispatchQueue(label: "us.okayplus.meerkat-runner.supervisor.io")
    private var managed: [UUID: Managed] = [:]
    /// Output by project. Kept after exit so a crashed server's logs stay readable.
    private var logs: [UUID: LogStore] = [:]

    /// - Parameters:
    ///   - logsDirectory: where `<project-id>.log` files go; nil keeps output in memory only.
    ///   - runtimeFile: `runtime.json` for re-adoption after relaunch; nil disables it.
    public init(logsDirectory: URL? = nil, runtimeFile: URL? = nil) {
        self.logsDirectory = logsDirectory
        self.runtimeFile = runtimeFile
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    final class Managed: @unchecked Sendable {
        var record: LaunchRecord
        let log: LogStore
        let isChild: Bool
        var stopRequested = false
        var exitSource: DispatchSourceProcess?
        var readSource: DispatchSourceRead?

        init(record: LaunchRecord, log: LogStore, isChild: Bool) {
            self.record = record
            self.log = log
            self.isChild = isChild
        }
    }

    // MARK: - Spawning

    /// Spawns an approved command.
    ///
    /// SECURITY (§8.1 rule 2): this is the only spawn entry point and it is hidden behind
    /// `@_spi(ApprovalGate)`. Only the `Approval` module may write `@_spi(ApprovalGate) import Supervisor`;
    /// reviewers grep for that attribute (and for `csp_spawn`) to audit every spawn call site.
    @_spi(ApprovalGate)
    public func spawn(_ spec: LaunchSpec) async throws(SupervisorError) -> LaunchRecord {
        guard managed[spec.projectID] == nil else { throw .alreadyRunning }

        let argv = Self.commandLine(for: spec)
        guard let executable = ExecutableResolver.resolve(
            argv[0], cwd: spec.workingDirectory, path: spec.environment["PATH"]
        ) else {
            throw .executableNotFound(argv[0])
        }
        var environment = spec.environment
        if environment["TERM"] == nil || environment["TERM"] == "dumb" {
            environment["TERM"] = "xterm-256color"
        }

        var primary: Int32 = -1
        var secondary: Int32 = -1
        let ptyError = csp_openpty(&primary, &secondary, Self.ptyColumns, Self.ptyRows)
        guard ptyError == 0 else { throw .ptyFailed(errno: ptyError) }

        var pid: pid_t = 0
        let envStrings = environment.map { "\($0.key)=\($0.value)" }
        let spawnError = Self.withCStrings(argv) { argvPointer in
            Self.withCStrings(envStrings) { envPointer in
                csp_spawn(executable, argvPointer, envPointer, spec.workingDirectory, secondary, &pid)
            }
        }
        close(secondary)
        guard spawnError == 0 else {
            close(primary)
            throw .spawnFailed(errno: spawnError)
        }

        // posix_spawn returns after exec, so this is the new image.
        let info = try? ProcessInfoReader.bsdInfo(pid: pid)
        let identity = ProcessIdentity(
            pid: pid,
            startTime: info.map { ProcessStartTime(seconds: $0.startSeconds, microseconds: $0.startMicroseconds) }
                ?? ProcessStartTime(seconds: 0, microseconds: 0),
            executablePath: (try? ProcessInfoReader.executablePath(pid: pid)) ?? executable
        )
        let record = LaunchRecord(projectID: spec.projectID, identity: identity, pgid: pid)
        let log = makeLog(for: spec.projectID, resume: false)
        logs[spec.projectID] = log
        let process = Managed(record: record, log: log, isChild: true)
        managed[spec.projectID] = process
        attachReader(process, primary: primary)
        attachExitSource(process)
        persistRuntime()
        logger.info("started a server")
        return record
    }

    static func commandLine(for spec: LaunchSpec) -> [String] {
        switch spec.command {
        case .argv(let args):
            return spec.wrapper + args
        case .shell(let string):
            // Only reachable for commands the user explicitly saved as shell commands (§6.2).
            let shell = spec.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
            return spec.wrapper + [shell, "-c", string]
        }
    }

    private func makeLog(for projectID: UUID, resume: Bool) -> LogStore {
        let url = logsDirectory?.appendingPathComponent("\(projectID.uuidString).log")
        return LogStore(fileURL: url, resume: resume) { [weak self] port in
            Task { await self?.portSeen(projectID: projectID, port: port) }
        }
    }

    private func portSeen(projectID: UUID, port: Int) {
        guard managed[projectID] != nil else { return }
        continuation.yield(.portInOutput(projectID: projectID, port: port))
    }

    /// Reads the PTY primary into the log until the child side closes.
    private func attachReader(_ process: Managed, primary: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: primary, queue: ioQueue)
        let log = process.log
        let box = SourceBox(source)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(primary, $0.baseAddress, $0.count) }
                if count > 0 {
                    log.append(Data(buffer[0..<count]))
                    continue
                }
                // 0 or EIO: the child side is closed. EAGAIN: drained for now.
                if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    box.cancel()
                }
                break
            }
        }
        source.setCancelHandler { close(primary) }
        process.readSource = source
        source.resume()
    }

    /// Watches the leader for exit. Children are reaped here (no zombies); adopted processes can't be.
    private func attachExitSource(_ process: Managed) {
        let pid = process.record.identity.pid
        let projectID = process.record.projectID
        let isChild = process.isChild
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        source.setEventHandler { [weak self] in
            let code = isChild ? Self.reap(pid) : nil
            Task { await self?.didExit(projectID: projectID, pid: pid, exitCode: code) }
        }
        process.exitSource = source
        source.resume()

        // If it already exited before the source was armed, handle that now.
        if isChild {
            var code: Int32 = 0
            if csp_reap(pid, &code) == 1 {
                Task { await didExit(projectID: projectID, pid: pid, exitCode: code) }
            }
        } else if kill(pid, 0) != 0, errno == ESRCH {
            Task { await didExit(projectID: projectID, pid: pid, exitCode: nil) }
        }
    }

    private static func reap(_ pid: pid_t) -> Int32? {
        var code: Int32 = 0
        for _ in 0..<50 {
            switch csp_reap(pid, &code) {
            case 1: return code
            case 0: usleep(10_000)
            default: return nil
            }
        }
        return nil
    }

    private func didExit(projectID: UUID, pid: pid_t, exitCode: Int32?) {
        guard let process = managed[projectID], process.record.identity.pid == pid else { return }
        managed[projectID] = nil
        process.exitSource?.cancel()
        // The read source cancels itself on EOF once the remaining output is drained.
        persistRuntime()
        continuation.yield(.exited(projectID: projectID, exitCode: exitCode, requested: process.stopRequested))
    }

    // MARK: - Queries

    public struct ManagedInfo: Sendable, Equatable {
        public var pgid: pid_t
        public var startedAt: Date
    }

    /// Servers Runner launched (or re-adopted), by project.
    public func snapshot() -> [UUID: ManagedInfo] {
        managed.mapValues { ManagedInfo(pgid: $0.record.pgid, startedAt: $0.record.startedAt) }
    }

    /// The project's output: live, kept from its last run, or loaded from its log file.
    public func log(for projectID: UUID) -> LogStore? {
        if let log = logs[projectID] { return log }
        guard let url = logsDirectory?.appendingPathComponent("\(projectID.uuidString).log"),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        let log = makeLog(for: projectID, resume: true)
        logs[projectID] = log
        return log
    }

    /// Whether Runner launched (or re-adopted) this project's running server.
    public func isManaged(_ projectID: UUID) -> Bool {
        managed[projectID] != nil
    }

    /// Records Runner currently tracks (for matching and `runtime.json`).
    public func records() -> [LaunchRecord] {
        managed.values.map(\.record)
    }

    /// Updates each leader's recorded executable path when the same process (same PID and start time)
    /// has exec'd another program, e.g. `bin/dev` → `exec ./bin/rails server`. A process with a different
    /// start time is never matched, so this can't adopt a reused PID.
    public func refreshIdentities() {
        for process in managed.values {
            let identity = process.record.identity
            guard let current = Self.currentIdentity(pid: identity.pid),
                  current.startTime == identity.startTime,
                  current.executablePath != identity.executablePath
            else { continue }
            process.record.identity.executablePath = current.executablePath
        }
    }

    // MARK: - Stopping

    /// Stops a server Runner launched: `killpg(pgid, SIGTERM)` → wait up to 5 s → SIGKILL each remaining
    /// group member. Identity is re-verified right before every signal (§6.5).
    public func stop(projectID: UUID, gracePeriod: Duration = ProcessSupervisor.stopGracePeriod) async throws(SupervisorError) {
        guard let process = managed[projectID] else { return }
        process.stopRequested = true
        let record = process.record

        if let current = Self.currentIdentity(pid: record.identity.pid) {
            guard current == record.identity else {
                process.stopRequested = false
                throw .identityMismatch
            }
            killpg(record.pgid, SIGTERM)
        } else {
            // Leader already gone: signal any verified members left in its group.
            for pid in Self.verifiedMembers(of: record) { kill(pid, SIGTERM) }
        }

        let deadline = ContinuousClock.now + gracePeriod
        while ContinuousClock.now < deadline {
            if Self.verifiedMembers(of: record).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for pid in Self.verifiedMembers(of: record) {
            kill(pid, SIGKILL)
        }
    }

    /// Stops every server Runner launched (footer "Stop All Managed Servers", quit).
    public func stopAll() async {
        await withTaskGroup(of: Void.self) { group in
            for projectID in managed.keys {
                group.addTask { try? await self.stop(projectID: projectID) }
            }
        }
    }

    /// Stops a matched server that was started elsewhere (e.g. a terminal), per §6.5.
    ///
    /// TODO(v0.2 step 3b)
    public func stopExternal(_ listener: Listener) async throws(SupervisorError) {
        throw .notImplemented
    }

    /// Current identity of a live process, or nil if it no longer exists.
    static func currentIdentity(pid: pid_t) -> ProcessIdentity? {
        guard let info = try? ProcessInfoReader.bsdInfo(pid: pid), info.pid == pid else { return nil }
        return ProcessIdentity(
            pid: pid,
            startTime: ProcessStartTime(seconds: info.startSeconds, microseconds: info.startMicroseconds),
            executablePath: (try? ProcessInfoReader.executablePath(pid: pid)) ?? ""
        )
    }

    /// Live members of the record's process group that are safe to signal: ours (same UID), still in
    /// that group, started no earlier than the leader, and not a shell, terminal app or launchd.
    static func verifiedMembers(of record: LaunchRecord) -> [pid_t] {
        guard let members = try? ProcessInfoReader.processGroupMembers(record.pgid) else { return [] }
        let leaderStart = record.identity.startTime
        let uid = getuid()
        return members.filter { pid in
            guard let info = try? ProcessInfoReader.bsdInfo(pid: pid), info.pgid == record.pgid else { return false }
            let start = ProcessStartTime(seconds: info.startSeconds, microseconds: info.startMicroseconds)
            let startedAfterLeader = (start.seconds, start.microseconds) >= (leaderStart.seconds, leaderStart.microseconds)
            return startedAfterLeader && !SignalPolicy.isForbidden(processName: info.name, pid: pid, uid: info.uid, currentUID: uid)
        }
    }

    // MARK: - Runtime records (§6.7)

    struct RuntimeFile: Codable {
        var version = 1
        var records: [LaunchRecord]
    }

    private func persistRuntime() {
        guard let runtimeFile else { return }
        do {
            let data = try JSONEncoder().encode(RuntimeFile(records: records()))
            try FileManager.default.createDirectory(
                at: runtimeFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: runtimeFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeFile.path)
        } catch {
            logger.error("Failed to write runtime records")
        }
    }

    /// Re-adopts servers launched before a relaunch whose PID, start time and executable still match;
    /// drops stale records. Logs resume from the file only. Returns the adopted project IDs.
    @discardableResult
    public func readopt(knownProjects: Set<UUID>) -> [UUID] {
        guard let runtimeFile,
              let data = try? Data(contentsOf: runtimeFile),
              let file = try? JSONDecoder().decode(RuntimeFile.self, from: data)
        else { return [] }

        var adopted: [UUID] = []
        for record in file.records where knownProjects.contains(record.projectID) && managed[record.projectID] == nil {
            guard let current = Self.currentIdentity(pid: record.identity.pid),
                  current.startTime == record.identity.startTime
            else { continue }
            var record = record
            record.identity.executablePath = current.executablePath
            let log = makeLog(for: record.projectID, resume: true)
            logs[record.projectID] = log
            let process = Managed(record: record, log: log, isChild: false)
            managed[record.projectID] = process
            attachExitSource(process)
            adopted.append(record.projectID)
        }
        persistRuntime()
        return adopted
    }

    // MARK: - Helpers

    /// Tests only: pretend the recorded identity is different (simulates PID reuse).
    func overrideIdentityForTesting(projectID: UUID, identity: ProcessIdentity) {
        managed[projectID]?.record.identity = identity
    }

    /// NULL-terminated array of C strings, valid for the duration of `body`.
    static func withCStrings<T>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    private final class SourceBox: @unchecked Sendable {
        private weak var source: DispatchSourceRead?

        init(_ source: DispatchSourceRead) {
            self.source = source
        }

        func cancel() {
            source?.cancel()
        }
    }
}
