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

    /// Per-process metadata that doesn't change for the life of a process, cached by `(pid, startTime)`.
    struct Metadata {
        var startTime: ProcessStartTime
        var executablePath: String
        var argv: [String]
    }

    private let uid: uid_t
    private let logger = RunnerLog.logger(category: "scanner")
    private var cache: [pid_t: Metadata] = [:]

    public init(uid: uid_t = getuid()) {
        self.uid = uid
    }

    /// One full scan (§4 steps 1–6). Processes that exit mid-scan or are protected are skipped
    /// silently; per-PID errors are never logged.
    ///
    /// Returns one `Listener` per (process, address, port). A socket inherited by several processes
    /// (e.g. a forked worker) is reported once, for the lowest PID. Use `ListenerGroup.group` to merge
    /// v4 + v6 listeners into rows.
    public func scan() -> [Listener] {
        let pids: [pid_t]
        do {
            pids = try ProcessInfoReader.listPIDs(uid: uid)
        } catch {
            logger.error("scan: listing PIDs failed: \(String(describing: error), privacy: .public)")
            return []
        }

        var listeners: [Listener] = []
        var seen = Set<SocketKey>()
        var live = Set<pid_t>()
        // Aggregate counts only (never per-PID) for diagnostics.
        var socketReadFailures = 0
        var permissionDenied = 0

        for pid in pids.sorted() {
            let sockets: [RawListenSocket]
            do {
                sockets = try ProcessInfoReader.listenSockets(pid: pid)
            } catch {
                socketReadFailures += 1
                if error == .permissionDenied { permissionDenied += 1 }
                continue
            }
            guard !sockets.isEmpty,
                  let info = try? ProcessInfoReader.bsdInfo(pid: pid), info.uid == uid
            else { continue }
            live.insert(pid)
            let metadata = metadata(for: pid, info: info)
            // cwd can change (rarely); read it fresh. Missing cwd is fine.
            let cwd = try? ProcessInfoReader.currentDirectory(pid: pid)

            for socket in sockets {
                let family: AddressFamily = socket.isIPv6 ? .v6 : .v4
                let address = AddressClassifier.classify(bytes: socket.localAddress, isIPv6: socket.isIPv6)
                let key = SocketKey(port: socket.port, family: family, address: address)
                // Same pid may hold the socket on several fds; parents usually have the lower PID.
                guard seen.insert(key).inserted else { continue }
                listeners.append(Listener(
                    pid: pid,
                    pgid: info.pgid,
                    ppid: info.ppid,
                    port: socket.port,
                    address: address,
                    family: family,
                    executablePath: metadata.executablePath,
                    argv: metadata.argv,
                    cwd: cwd,
                    startTime: metadata.startTime
                ))
            }
        }

        cache = cache.filter { live.contains($0.key) }
        logger.debug(
            "scan: \(pids.count, privacy: .public) pids, \(listeners.count, privacy: .public) listeners, \(socketReadFailures, privacy: .public) fd-list failures (\(permissionDenied, privacy: .public) EPERM)"
        )
        return listeners.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    private struct SocketKey: Hashable {
        var port: Int
        var family: AddressFamily
        var address: ListenAddress
    }

    private func metadata(for pid: pid_t, info: BSDInfo) -> Metadata {
        let startTime = ProcessStartTime(seconds: info.startSeconds, microseconds: info.startMicroseconds)
        if let cached = cache[pid], cached.startTime == startTime {
            return cached
        }
        let path = (try? ProcessInfoReader.executablePath(pid: pid)) ?? info.name
        let argv = (try? ProcessInfoReader.arguments(pid: pid)) ?? []
        let metadata = Metadata(startTime: startTime, executablePath: path, argv: argv)
        cache[pid] = metadata
        return metadata
    }
}
