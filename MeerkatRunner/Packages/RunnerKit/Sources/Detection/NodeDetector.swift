import Foundation
import Models

/// Reads `package.json`, lockfiles. Proposes `<pm> run <script>` for `dev`, `start`, `serve`, `develop`, `preview` (that order).
///
/// - Package manager by lockfile: pnpm-lock.yaml → pnpm, yarn.lock → yarn, bun.lockb/bun.lock → bun,
///   package-lock.json → npm; else the `packageManager` field; else npm.
/// - Framework from deps (next, vite, astro, @remix-run/*, nuxt, @sveltejs/kit).
/// - `start` gets the note "needs a build first" for Next/Nuxt.
/// - Include `pre<name>`/`post<name>` scripts in `resolvedScript` when present (they run under npm).
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct NodeDetector: Detector {
    public static let id: DetectorID = .node

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        // TODO(v0.2): implement per AGENTS.md §5 detector table; add fixtures + expected.json in Tests/Fixtures.
        []
    }
}
