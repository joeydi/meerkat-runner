import Foundation
import Models
import ProcInfo

public enum SupervisorError: Error, Sendable, Equatable {
    case executableNotFound(String)
    case spawnFailed(errno: Int32)
    case ptyFailed(errno: Int32)
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

    public init(projectID: UUID, identity: ProcessIdentity, pgid: pid_t) {
        self.projectID = projectID
        self.identity = identity
        self.pgid = pgid
    }
}

/// Spawns, tracks, and stops dev servers (AGENTS.md §6).
public actor ProcessSupervisor {
    public static let stopGracePeriod: Duration = .seconds(5)
    public static let portFreeTimeout: Duration = .seconds(10)

    private let logger = RunnerLog.logger(category: "supervisor")
    private var running: [UUID: LaunchRecord] = [:]

    public init() {}

    /// Spawns an approved command.
    ///
    /// SECURITY (§8.1 rule 2): this is the only spawn entry point and it is hidden behind
    /// `@_spi(ApprovalGate)`. Only the `Approval` module may write `@_spi(ApprovalGate) import Supervisor`;
    /// reviewers grep for that attribute to audit every spawn call site.
    ///
    /// TODO(v0.2): `posix_spawn` with `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT`, PTY slave dup2'd
    /// to fds 0–2 (`PTY.open`), `posix_spawn_file_actions_addchdir_np` for cwd; resolve `.argv[0]` against
    /// the final PATH; `.shell` runs `[$SHELL, "-c", string]`. Record in memory and `runtime.json`,
    /// attach a `DispatchSource.makeProcessSource(.exit)`, start reading the PTY into `LogBuffer`.
    @_spi(ApprovalGate)
    public func spawn(_ spec: LaunchSpec) async throws(SupervisorError) -> LaunchRecord {
        throw .notImplemented
    }

    /// Stops a server Runner launched: `killpg(pgid, SIGTERM)` → wait 5 s → `killpg(pgid, SIGKILL)`.
    ///
    /// TODO(v0.2): verify identity (pid + start time + executable path) right before each signal.
    public func stop(projectID: UUID) async throws(SupervisorError) {
        throw .notImplemented
    }

    /// Stops a matched server that was started elsewhere (e.g. a terminal), per §6.5:
    /// signal the group only if it contains no shell/terminal and differs from the parent shell's group;
    /// otherwise signal the PID and its descendants, deepest first.
    ///
    /// TODO(v0.2)
    public func stopExternal(_ listener: Listener) async throws(SupervisorError) {
        throw .notImplemented
    }

    /// Records Runner currently tracks (for matching and `runtime.json`).
    public func records() -> [LaunchRecord] {
        Array(running.values)
    }
}
