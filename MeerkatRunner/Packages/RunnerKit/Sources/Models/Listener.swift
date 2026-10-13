import Foundation

/// A TCP socket in LISTEN state owned by the current user (AGENTS.md §4).
public struct Listener: Hashable, Sendable {
    public var pid: pid_t
    public var pgid: pid_t
    public var ppid: pid_t
    public var port: Int
    public var address: ListenAddress
    public var family: AddressFamily
    public var executablePath: String
    public var argv: [String]
    public var cwd: String?
    /// From `proc_bsdinfo`; checked again before any signal is sent (PID-reuse guard).
    public var startTime: ProcessStartTime

    public init(
        pid: pid_t,
        pgid: pid_t,
        ppid: pid_t,
        port: Int,
        address: ListenAddress,
        family: AddressFamily,
        executablePath: String,
        argv: [String],
        cwd: String?,
        startTime: ProcessStartTime
    ) {
        self.pid = pid
        self.pgid = pgid
        self.ppid = ppid
        self.port = port
        self.address = address
        self.family = family
        self.executablePath = executablePath
        self.argv = argv
        self.cwd = cwd
        self.startTime = startTime
    }

    /// Short process name for display, e.g. "node".
    public var processName: String {
        (executablePath as NSString).lastPathComponent
    }

    /// Wildcard binds are reachable from the LAN.
    public var isLANVisible: Bool { address == .wildcard }
}

/// Process start time as reported by `proc_bsdinfo` (`pbi_start_tvsec` / `pbi_start_tvusec`).
/// Stored as plain integers rather than `timeval` so it is `Codable` and `Hashable`.
public struct ProcessStartTime: Hashable, Codable, Sendable {
    public var seconds: UInt64
    public var microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000)
    }
}

public enum ListenAddress: Hashable, Sendable {
    /// 127.0.0.0/8 or ::1
    case loopback
    /// 0.0.0.0 or :: — LAN-reachable.
    case wildcard
    case specific(String)
}

public enum AddressFamily: Hashable, Sendable {
    case v4
    case v6
}
