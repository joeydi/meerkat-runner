import Foundation

/// Processes Runner must never signal (AGENTS.md §6.5, §8.1 rule 4). Keep this a data table.
public enum SignalPolicy {
    public static let shellNames: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "-sh", "dash", "nu", "tmux", "screen",
    ]

    public static let terminalAppNames: Set<String> = [
        "Terminal", "iTerm2", "Warp", "WezTerm", "wezterm-gui", "alacritty", "kitty", "ghostty", "Hyper",
        "Code Helper", "Cursor Helper",
    ]

    public static let alwaysForbidden: Set<String> = ["launchd"]

    /// `name` is the process name / executable basename.
    public static func isForbidden(processName name: String, pid: pid_t, uid: uid_t, currentUID: uid_t = getuid()) -> Bool {
        if pid <= 1 || uid != currentUID { return true }
        return shellNames.contains(name) || terminalAppNames.contains(name) || alwaysForbidden.contains(name)
    }
}
