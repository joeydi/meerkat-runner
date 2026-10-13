import Foundation

/// Port prediction (AGENTS.md §5 "Port prediction"):
/// explicit `--port`/`-p` in the resolved script → `PORT=` in selected env files → framework default.
public enum PortPrediction {
    public static let frameworkDefaults: [String: Int] = [
        "Next.js": 3000,
        "Vite": 5173,
        "Astro": 4321,
        "Remix": 3000,
        "Nuxt": 3000,
        "SvelteKit": 5173,
        "Django": 8000,
        "Rails": 3000,
        "Flask": 5000,
        "Laravel": 8000,
    ]

    /// Ports known to collide with macOS services (AirPlay Receiver).
    public static let systemConflicts: Set<Int> = [5000, 7000]

    /// Extracts `--port N`, `--port=N` or `-p N` from a script.
    public static func explicitPort(in script: String) -> Int? {
        let pattern = #"(?:--port[=\s]+|-p\s+)(\d{2,5})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script)
        else { return nil }
        return Int(script[range])
    }

    /// Reads only the `PORT` key from an env file. Other values are never read into memory beyond parsing.
    public static func envPort(in envFile: String) -> Int? {
        for line in envFile.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let body = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
            guard body.hasPrefix("PORT=") else { continue }
            let value = body.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return Int(value)
        }
        return nil
    }

    public static func predict(script: String?, envFiles: [String], framework: String?) -> Int? {
        if let script, let port = explicitPort(in: script) { return port }
        for file in envFiles {
            if let port = envPort(in: file) { return port }
        }
        return framework.flatMap { frameworkDefaults[$0] }
    }
}
