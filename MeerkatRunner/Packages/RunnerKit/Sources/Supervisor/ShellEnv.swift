import Foundation

/// Captures the user's login environment, since GUI apps launched by launchd don't inherit
/// shell config (nvm, asdf, mise, fnm, pyenv, Homebrew PATH). AGENTS.md §6.1.
///
/// Runs `$SHELL -l -i -c '<sentinel>; env -0; <sentinel>'` once (stdin from /dev/null, 5 s timeout),
/// parses only between the sentinels, and caches the result. This runs the user's own shell with a
/// fixed command; it is not a project command and doesn't go through the approval gate.
/// Values are never logged.
public actor ShellEnv {
    public static let timeout: Duration = .seconds(5)
    public static let fallbackPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    public struct Capture: Sendable {
        public var environment: [String: String]
        public var capturedAt: Date
        /// False when the shell timed out or failed and the fallback PATH is in use.
        public var isComplete: Bool
    }

    private var cached: Capture?
    private var inFlight: Task<Capture, Never>?

    public init() {}

    /// The cached login environment, capturing it on first use.
    public func environment() async -> [String: String] {
        await capture().environment
    }

    public func capture() async -> Capture {
        if let cached { return cached }
        if let inFlight { return await inFlight.value }
        let task = Task.detached { Self.run() }
        inFlight = task
        let result = await task.value
        cached = result
        inFlight = nil
        return result
    }

    /// "Reload shell environment" in Settings.
    public func reload() async -> Capture {
        cached = nil
        return await capture()
    }

    /// Parses `env -0` output found between two sentinel markers, ignoring any banner noise around them.
    public static func parse(_ output: Data, sentinel: String) -> [String: String]? {
        let marker = Data(sentinel.utf8)
        guard let first = output.range(of: marker),
              let second = output.range(of: marker, in: first.upperBound..<output.endIndex)
        else { return nil }
        let body = output[first.upperBound..<second.lowerBound]
        var env: [String: String] = [:]
        for entry in body.split(separator: 0) {
            let string = String(decoding: entry, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            guard let equals = string.firstIndex(of: "="), equals != string.startIndex else { continue }
            env[String(string[..<equals])] = String(string[string.index(after: equals)...])
        }
        return env
    }

    static func fallback() -> Capture {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fallbackPATH
        return Capture(environment: environment, capturedAt: .now, isComplete: false)
    }

    /// Blocking; called on a detached task.
    static func run() -> Capture {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let sentinel = "__MEERKAT_ENV_\(UUID().uuidString)__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '%s' '\(sentinel)'; /usr/bin/env -0; printf '%s' '\(sentinel)'"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let collected = Collected()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collected.append(handle.availableData)
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return fallback()
        }

        let timedOut = finished.wait(timeout: .now() + .seconds(5)) == .timedOut
        if timedOut { process.terminate() }
        // A background job started by an rc file can hold the pipe open; don't wait for EOF.
        Thread.sleep(forTimeInterval: 0.1)
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.append(pipe.fileHandleForReading.availableDataNonBlocking())

        guard let environment = parse(collected.data, sentinel: sentinel), environment["PATH"] != nil else {
            return fallback()
        }
        return Capture(environment: environment, capturedAt: .now, isComplete: true)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            lock.lock()
            storage.append(data)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}

private extension FileHandle {
    /// Whatever is buffered right now, without blocking on EOF.
    func availableDataNonBlocking() -> Data {
        let fd = fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}
