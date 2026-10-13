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

/// Thin, synchronous wrappers over the CProcInfo shim (AGENTS.md §4 "Algorithm (one scan)").
/// Buffers are sized explicitly and passed with their capacity; the shim never writes past it.
public enum ProcessInfoReader {
    /// Max listening sockets read per process.
    static let maxSocketsPerProcess = 256

    /// Step 1: `proc_listpids(PROC_UID_ONLY, getuid(), …)`.
    public static func listPIDs(uid: uid_t = getuid()) throws(ProcInfoError) -> [pid_t] {
        let hint = cpi_pid_count_hint(uid)
        guard hint > 0 else { throw ProcInfoError(errno: errno) }
        // Headroom for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(hint) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            cpi_list_pids(uid, buffer.baseAddress, Int32(buffer.count))
        }
        guard count >= 0 else { throw ProcInfoError(errno: errno) }
        return pids.prefix(min(Int(count), pids.count)).filter { $0 > 0 }
    }

    /// Step 5: `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)`.
    public static func bsdInfo(pid: pid_t) throws(ProcInfoError) -> BSDInfo {
        var raw = cpi_bsdinfo()
        guard cpi_bsd_info(pid, &raw) == 0 else { throw ProcInfoError(errno: errno) }
        return BSDInfo(
            pid: raw.pid,
            ppid: raw.ppid,
            pgid: raw.pgid,
            uid: raw.uid,
            name: cString(fromTuple: raw.name),
            startSeconds: raw.start_sec,
            startMicroseconds: raw.start_usec
        )
    }

    /// Steps 2–4: `PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO`, keeping TCP sockets in `TSI_S_LISTEN`.
    public static func listenSockets(pid: pid_t) throws(ProcInfoError) -> [RawListenSocket] {
        var buffer = [cpi_listen_socket](repeating: cpi_listen_socket(), count: maxSocketsPerProcess)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            cpi_listen_sockets(pid, pointer.baseAddress, Int32(pointer.count))
        }
        guard count >= 0 else { throw ProcInfoError(errno: errno) }
        return buffer.prefix(min(Int(count), buffer.count)).map { socket in
            let isIPv6 = socket.is_ipv6 != 0
            let address = withUnsafeBytes(of: socket.addr) { Array($0.prefix(isIPv6 ? 16 : 4)) }
            return RawListenSocket(port: Int(socket.port), isIPv6: isIPv6, localAddress: address)
        }
    }

    /// `proc_pidpath`.
    public static func executablePath(pid: pid_t) throws(ProcInfoError) -> String {
        try readPath { cpi_pidpath(pid, $0, $1) }
    }

    /// `PROC_PIDVNODEPATHINFO` → `pvi_cdir.vip_path`.
    public static func currentDirectory(pid: pid_t) throws(ProcInfoError) -> String {
        try readPath { cpi_cwd(pid, $0, $1) }
    }

    private static func readPath(
        _ read: (UnsafeMutablePointer<CChar>?, Int) -> Int32
    ) throws(ProcInfoError) -> String {
        var buffer = [CChar](repeating: 0, count: Int(CPI_PATH_MAX))
        let length = buffer.withUnsafeMutableBufferPointer { read($0.baseAddress, $0.count) }
        guard length > 0 else { throw ProcInfoError(errno: errno) }
        let bytes = buffer.prefix(min(Int(length), buffer.count)).prefix { $0 != 0 }
        return String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Reads a NUL-terminated string out of an imported fixed-size C array (a Swift tuple).
    private static func cString<T>(fromTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
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
