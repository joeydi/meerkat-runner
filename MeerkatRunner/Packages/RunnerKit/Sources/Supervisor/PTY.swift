import Darwin

/// Pseudo-terminal for a spawned server (AGENTS.md §6.2): `openpty`, window 120×40 via `TIOCSWINSZ`,
/// so tools see `isatty(1) == true` and keep colour/progress output.
struct PTY {
    static let columns: UInt16 = 120
    static let rows: UInt16 = 40

    let primary: Int32
    let secondary: Int32

    /// TODO(v0.2): `openpty(&primary, &secondary, nil, nil, &winsize)`; set O_NONBLOCK and FD_CLOEXEC on
    /// the primary; close the secondary in the parent after spawn.
    static func open() throws(SupervisorError) -> PTY {
        throw .notImplemented
    }
}
