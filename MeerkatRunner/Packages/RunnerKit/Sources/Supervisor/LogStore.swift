import Foundation

/// One server's output: the in-memory ring of recent lines plus the rotating log file
/// (`~/Library/Logs/MeerkatRunner/<project-id>.log`, rotated at 5 MB, 3 kept, mode 0600). AGENTS.md §6.3.
///
/// Written from the PTY read handler on a background queue and read by the log window, so all state
/// is behind a lock. Contains raw output; redact before display or export (`Redactor`).
public final class LogStore: @unchecked Sendable {
    public static let rotateBytes = 5 * 1_024 * 1_024
    public static let keptFiles = 3
    /// How much of an existing log file to load when re-adopting a server after relaunch.
    static let resumeBytes = 256 * 1_024

    /// `http://localhost:5173`, `http://127.0.0.1:3000`, `http://[::1]:4321`, … (§6.4).
    static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):(\d{2,5})"#
    )

    public let fileURL: URL?
    private let lock = NSLock()
    private var buffer = LogBuffer()
    private var handle: FileHandle?
    private var fileSize = 0
    private var version = 0
    private var reportedPort = false
    private let onPort: @Sendable (Int) -> Void

    /// - Parameters:
    ///   - fileURL: log file; nil keeps output in memory only (tests).
    ///   - resume: load the tail of an existing file first (re-adopted servers).
    ///   - onPort: called once with the first local URL port seen in the output.
    public init(fileURL: URL?, resume: Bool = false, onPort: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.onPort = onPort
        guard let fileURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if resume, let tail = Self.tail(of: fileURL, bytes: Self.resumeBytes) {
            buffer.append(tail)
            // Complete a trailing partial line so new output starts on its own line.
            if tail.last != UInt8(ascii: "\n") { buffer.append(Data("\n".utf8)) }
        }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        fileSize = Int((try? handle?.seekToEnd()) ?? 0)
    }

    deinit {
        try? handle?.close()
    }

    /// Appends raw PTY output.
    public func append(_ data: Data) {
        var port: Int?
        lock.lock()
        let lines = buffer.append(data)
        version += 1
        writeLocked(data)
        if !reportedPort {
            port = lines.lazy.compactMap { Self.port(in: $0.plain) }.first
            if port != nil { reportedPort = true }
        }
        lock.unlock()
        if let port { onPort(port) }
    }

    /// Lines oldest → newest, plus a version that changes on every append or clear.
    public func snapshot() -> (version: Int, lines: [LogBuffer.Line]) {
        lock.lock()
        defer { lock.unlock() }
        return (version, buffer.lines)
    }

    /// Clears the in-memory lines (the file keeps its history).
    public func clear() {
        lock.lock()
        buffer.clear()
        version += 1
        lock.unlock()
    }

    static func port(in line: String) -> Int? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = urlPattern.firstMatch(in: line, range: range),
              let portRange = Range(match.range(at: 1), in: line)
        else { return nil }
        return Int(line[portRange])
    }

    // MARK: - File

    private func writeLocked(_ data: Data) {
        guard let handle else { return }
        try? handle.write(contentsOf: data)
        fileSize += data.count
        if fileSize >= Self.rotateBytes { rotateLocked() }
    }

    /// `x.log` → `x.log.1` → `x.log.2`; the oldest beyond `keptFiles` is deleted.
    private func rotateLocked() {
        guard let fileURL else { return }
        try? handle?.close()
        let fm = FileManager.default
        let path = fileURL.path
        try? fm.removeItem(atPath: "\(path).\(Self.keptFiles - 1)")
        for index in stride(from: Self.keptFiles - 2, through: 1, by: -1) {
            try? fm.moveItem(atPath: "\(path).\(index)", toPath: "\(path).\(index + 1)")
        }
        try? fm.moveItem(atPath: path, toPath: "\(path).1")
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try? FileHandle(forWritingTo: fileURL)
        fileSize = 0
    }

    static func tail(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        // Drop the partial first line when starting mid-file.
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = Data(data[data.index(after: newline)...])
        }
        return data
    }
}
