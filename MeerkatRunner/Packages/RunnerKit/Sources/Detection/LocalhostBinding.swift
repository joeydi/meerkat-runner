import Foundation
import Models

/// "Bind to localhost only" (AGENTS.md §6.6). Runner can't force a bind address, so each framework
/// entry adds the flag or env that asks for 127.0.0.1. The result is part of the approved,
/// fingerprinted command. Keep the whole table in this file; it's covered by `LocalhostBindingTests`.
public enum LocalhostBinding {
    public static let address = "127.0.0.1"

    /// Fallback for commands Runner doesn't recognise: many dev servers read `HOST`.
    public static let generic = BindOverride(environment: ["HOST": address])

    /// Node dev-server CLIs (first word of the script) → the flags that bind 127.0.0.1.
    static let nodeFlags: [String: [String]] = [
        "next": ["-H", address],
        "vite": ["--host", address],
        "astro": ["--host", address],
        "nuxt": ["--host", address],
        "nuxi": ["--host", address],
    ]

    /// What the bind adds for `proposal`, or nil when Runner can't do it (Docker Compose publishes
    /// ports itself). An empty override means the command already binds 127.0.0.1.
    /// - Parameter port: the project's port, for commands that take `address:port` (Django).
    public static func override(for proposal: Proposal?, port: Int?) -> BindOverride? {
        guard let proposal else { return generic }
        guard case .argv(let argv) = proposal.command else { return generic }
        switch proposal.detector {
        case .compose:
            return nil
        case .static:
            return argv.contains(address) ? BindOverride() : generic
        case .node, .monorepo:
            return node(proposal, argv: argv)
        case .django:
            return BindOverride(arguments: ["\(address):\(port ?? 8000)"])
        case .rails:
            // `bin/dev` hands its arguments to foreman, not Rails; Rails reads BINDING instead.
            return argv.last == "server" ? BindOverride(arguments: ["-b", address])
                : BindOverride(environment: ["BINDING": address])
        case .python:
            return argv.contains("uvicorn") || argv.contains("flask") ? BindOverride(arguments: ["--host", address]) : generic
        case .laravel:
            return BindOverride(arguments: ["--host=\(address)"])
        case .procfile, .make, .just, .custom:
            return generic
        }
    }

    /// Flags only when the script is a single call to a known CLI, e.g. `next dev --turbopack`.
    /// Package managers append extra arguments to the end of the script, so anything chained
    /// (`a && b`) or unknown gets `HOST` instead.
    static func node(_ proposal: Proposal, argv: [String]) -> BindOverride {
        guard let script = proposal.label.split(separator: " ").last.map(String.init),
              let body = scriptBody(named: script, in: proposal.resolvedScript),
              !body.contains(where: { "&|;<>`$\n".contains($0) })
        else { return generic }
        let words = body.split(separator: " ").map(String.init).drop { $0.contains("=") || $0 == "cross-env" }
        guard let tool = words.first, var flags = nodeFlags[tool] else { return generic }
        if tool == "next", let sub = words.dropFirst().first, !["dev", "start"].contains(sub) { return generic }
        // npm needs `--` before arguments meant for the script; pnpm, yarn and bun pass them through.
        if argv.first == "npm" { flags.insert("--", at: 0) }
        return BindOverride(arguments: flags)
    }

    /// The script's own line from a resolved script that may also list `pre`/`post` hooks.
    static func scriptBody(named name: String, in resolved: String?) -> String? {
        guard let resolved else { return nil }
        guard resolved.contains("\n") else { return resolved }
        return resolved.split(separator: "\n")
            .first { $0.hasPrefix("\(name): ") }
            .map { String($0.dropFirst(name.count + 2)) }
    }
}
