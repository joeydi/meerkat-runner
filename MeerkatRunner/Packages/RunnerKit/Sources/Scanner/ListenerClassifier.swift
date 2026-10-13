import Foundation
import Models

/// Maps a process's argv / executable to a framework label (AGENTS.md §4 "Classifier").
/// Keep the whole table in this file; it is covered by `ScannerTests`.
public enum ListenerClassifier {
    struct Rule: Sendable {
        let label: String
        /// Returns true when the (lowercased basename) argv matches.
        let matches: @Sendable (_ args: [String]) -> Bool
    }

    /// Ordered: the first match wins. `node` is the fallback and must stay last.
    static let rules: [Rule] = [
        Rule(label: "Next.js") { args in containsSequence(args, ["next", "dev"]) || args.contains("next-server") },
        Rule(label: "Vite") { args in args.contains("vite") },
        Rule(label: "Astro") { args in containsSequence(args, ["astro", "dev"]) },
        Rule(label: "Rails") { args in
            containsSequence(args, ["rails", "s"]) || containsSequence(args, ["rails", "server"]) || args.contains("puma")
        },
        Rule(label: "Django") { args in containsSequence(args, ["manage.py", "runserver"]) },
        Rule(label: "Python") { args in
            args.contains("uvicorn") || args.contains("gunicorn") || containsSequence(args, ["flask", "run"])
        },
        Rule(label: "Laravel") { args in containsSequence(args, ["artisan", "serve"]) },
        Rule(label: "Node") { args in args.first == "node" },
    ]

    /// Returns a framework label such as "Next.js", or `nil` if nothing matches.
    public static func classify(executablePath: String, argv: [String]) -> String? {
        var tokens = argv.map(normalize)
        if tokens.isEmpty {
            tokens = [normalize(executablePath)]
        }
        return rules.first { $0.matches(tokens) }?.label
    }

    /// Basename, lowercased: `/path/to/node_modules/.bin/next` → `next`.
    static func normalize(_ token: String) -> String {
        (token as NSString).lastPathComponent.lowercased()
    }

    static func containsSequence(_ args: [String], _ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, args.count >= sequence.count else { return false }
        for start in 0...(args.count - sequence.count) where Array(args[start..<start + sequence.count]) == sequence {
            return true
        }
        return false
    }
}
