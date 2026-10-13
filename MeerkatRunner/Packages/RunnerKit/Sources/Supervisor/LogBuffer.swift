import Foundation

/// In-memory ring of the last N output lines (AGENTS.md §6.3). Keeps raw bytes with ANSI for the
/// viewer and a stripped copy for search. Disk logging (rotate at 5 MB, keep 3) is separate.
public struct LogBuffer: Sendable {
    public static let defaultCapacity = 5_000

    public struct Line: Sendable, Equatable {
        public var raw: String
        public var plain: String
    }

    public let capacity: Int
    private var storage: [Line] = []
    private var head = 0
    private var partial = Data()

    public init(capacity: Int = LogBuffer.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { storage.count }

    /// Lines oldest → newest.
    public var lines: [Line] {
        guard storage.count == capacity else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    /// Appends raw PTY bytes; incomplete trailing lines are held until the next newline.
    public mutating func append(_ bytes: Data) {
        partial.append(bytes)
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            var lineData = partial[partial.startIndex..<newline]
            if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
            appendLine(String(decoding: lineData, as: UTF8.self))
            partial = Data(partial[partial.index(after: newline)...])
        }
    }

    public mutating func clear() {
        storage.removeAll()
        head = 0
        partial.removeAll()
    }

    private mutating func appendLine(_ raw: String) {
        let line = Line(raw: raw, plain: ANSI.strip(raw))
        if storage.count < capacity {
            storage.append(line)
        } else {
            storage[head] = line
            head = (head + 1) % capacity
        }
    }
}

public enum ANSI {
    private static let escape = try! NSRegularExpression(
        pattern: #"\x{1B}(?:\[[0-?]*[ -/]*[@-~]|\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)|[@-Z\\-_])"#
    )

    public static func strip(_ text: String) -> String {
        escape.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}
