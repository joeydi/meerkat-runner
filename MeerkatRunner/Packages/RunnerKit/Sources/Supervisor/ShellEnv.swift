import Foundation

/// Captures the user's login environment, since GUI apps launched by launchd don't inherit
/// shell config (AGENTS.md §6.1).
public actor ShellEnv {
    public static let timeout: Duration = .seconds(5)
    public static let fallbackPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    private var cached: [String: String]?

    public init() {}

    /// Returns the cached login environment, capturing it on first use.
    ///
    /// TODO(v0.2): run `$SHELL` (fallback `/bin/zsh`) with `-l -i -c` and a command that prints a unique
    /// sentinel, `env -0`, then the sentinel again; parse with `parse(_:sentinel:)`. On timeout use
    /// `fallbackPATH` and surface a non-blocking notice. Never log values.
    public func environment() async -> [String: String] {
        if let cached { return cached }
        let env = ["PATH": Self.fallbackPATH]
        cached = env
        return env
    }

    /// "Reload shell environment" in Settings.
    public func invalidate() {
        cached = nil
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
}
