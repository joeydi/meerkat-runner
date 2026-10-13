import CProcInfo
import Darwin

/// Errors from libproc / sysctl. Callers skip EPERM/ESRCH silently (process exited or protected);
/// never log per-PID errors at default level (AGENTS.md §4).
public enum ProcInfoError: Error, Sendable, Equatable {
    case permissionDenied
    case noSuchProcess
    case bufferTooSmall
    case malformed
    case errno(Int32)

    init(errno code: Int32) {
        switch code {
        case EPERM: self = .permissionDenied
        case ESRCH: self = .noSuchProcess
        default: self = .errno(code)
        }
    }
}

/// `proc_bsdinfo` fields Runner cares about.
public struct BSDInfo: Sendable, Equatable {
    public var pid: pid_t
    public var ppid: pid_t
    public var pgid: pid_t
    public var uid: uid_t
    public var name: String
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
}

/// A TCP listening socket found on a process (raw; classification happens in Scanner).
public struct RawListenSocket: Sendable, Equatable {
    public var port: Int
    public var isIPv6: Bool
    /// Local address bytes: 4 for IPv4, 16 for IPv6.
    public var localAddress: [UInt8]
}

/// Thin, synchronous wrappers over libproc. Every `Unsafe*` buffer has an explicit size check.
///
/// TODO(v0.1): implement each call per AGENTS.md §4 "Algorithm (one scan)".
public enum ProcessInfoReader {
    /// Step 1: `proc_listpids(PROC_UID_ONLY, getuid(), …)`.
    public static func listPIDs(uid: uid_t = getuid()) throws(ProcInfoError) -> [pid_t] {
        // TODO(v0.1): call proc_listpids twice (size query, then fill) with headroom for new PIDs.
        []
    }

    /// Step 5: `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)`.
    public static func bsdInfo(pid: pid_t) throws(ProcInfoError) -> BSDInfo {
        // TODO(v0.1)
        throw .noSuchProcess
    }

    /// Steps 2–4: `PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO`, keeping TCP sockets in `TSI_S_LISTEN`.
    public static func listenSockets(pid: pid_t) throws(ProcInfoError) -> [RawListenSocket] {
        // TODO(v0.1)
        []
    }

    /// `proc_pidpath`.
    public static func executablePath(pid: pid_t) throws(ProcInfoError) -> String {
        // TODO(v0.1)
        throw .noSuchProcess
    }

    /// `PROC_PIDVNODEPATHINFO` → `pvi_cdir.vip_path`.
    public static func currentDirectory(pid: pid_t) throws(ProcInfoError) -> String {
        // TODO(v0.1)
        throw .noSuchProcess
    }

    /// `sysctl([CTL_KERN, KERN_PROCARGS2, pid])` → argv.
    public static func arguments(pid: pid_t) throws(ProcInfoError) -> [String] {
        let argmax = cpi_argmax()
        guard argmax > 0 else { throw ProcInfoError(errno: errno) }
        var buffer = [CChar](repeating: 0, count: Int(argmax))
        let length = buffer.withUnsafeMutableBufferPointer { ptr in
            cpi_procargs2(pid, ptr.baseAddress, ptr.count)
        }
        guard length >= 0 else { throw ProcInfoError(errno: errno) }
        return try parseProcArgs2(buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) })
    }

    /// Parses a KERN_PROCARGS2 buffer: `int32 argc`, exec path, NUL padding, then argc NUL-terminated args.
    public static func parseProcArgs2(_ bytes: [UInt8]) throws(ProcInfoError) -> [String] {
        let argcSize = MemoryLayout<Int32>.size
        guard bytes.count >= argcSize else { throw .malformed }
        let argc = bytes.prefix(argcSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { throw .malformed }

        var index = argcSize
        // Skip the exec path.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        // Skip NUL padding.
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var args: [String] = []
        args.reserveCapacity(Int(argc))
        while args.count < Int(argc), index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            args.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}
