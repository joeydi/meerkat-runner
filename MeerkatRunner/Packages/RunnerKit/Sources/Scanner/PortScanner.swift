import Foundation
import Models
import ProcInfo

/// Enumerates TCP listeners owned by the current user via libproc (AGENTS.md §4).
/// Never shells out to `lsof` / `netstat`.
public actor PortScanner {
    public enum Interval {
        /// Menu open.
        public static let active: Duration = .seconds(2)
        /// Menu closed (feeds the badge count).
        public static let idle: Duration = .seconds(15)
    }

    private let logger = RunnerLog.logger(category: "scanner")

    public init() {}

    /// One full scan. Processes that exit mid-scan or are protected are skipped silently.
    ///
    /// TODO(v0.1): implement §4 steps 1–6, caching per-PID metadata by `(pid, startTime)`,
    /// and de-duplicating v4+v6 listeners on the same port into one row (done by the registry).
    public func scan() async -> [Listener] {
        []
    }
}
