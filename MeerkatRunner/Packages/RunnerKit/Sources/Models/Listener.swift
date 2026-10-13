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

/// One process listening on one port, possibly on several addresses (e.g. `127.0.0.1` and `::1`).
/// The dropdown shows one row per group (AGENTS.md §4 step 6).
public struct ListenerGroup: Identifiable, Hashable, Sendable {
    /// Non-empty; every element has the same `pid` and `port`.
    public var listeners: [Listener]

    public init?(_ listeners: [Listener]) {
        guard let first = listeners.first,
              listeners.allSatisfy({ $0.pid == first.pid && $0.port == first.port })
        else { return nil }
        self.listeners = listeners
    }

    public var id: String { "\(primary.pid):\(primary.port)" }
    public var primary: Listener { listeners[0] }
    public var pid: pid_t { primary.pid }
    public var port: Int { primary.port }
    public var processName: String { primary.processName }
    public var cwd: String? { primary.cwd }
    /// Any wildcard bind makes the server reachable from the LAN.
    public var isLANVisible: Bool { listeners.contains(where: \.isLANVisible) }

    /// Groups listeners by `(pid, port)`, sorted by port then PID. IPv4 sorts before IPv6 within a group.
    public static func group(_ listeners: [Listener]) -> [ListenerGroup] {
        struct Key: Hashable {
            var pid: pid_t
            var port: Int
        }
        let grouped = Dictionary(grouping: listeners) { Key(pid: $0.pid, port: $0.port) }
        return grouped.values
            .compactMap { members in
                ListenerGroup(members.sorted { ($0.family == .v4 ? 0 : 1) < ($1.family == .v4 ? 0 : 1) })
            }
            .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }
}
