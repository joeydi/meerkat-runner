import Foundation
import Models

/// Listeners owned by desktop apps (Dropbox, Adobe, Raycast, editor helpers, …). Hidden from
/// "Other listeners" by default via the "Hide app listeners" setting. Keep the keep-list a data table.
public enum AppListeners {
    /// App bundles that exist to run dev servers; their listeners stay visible.
    /// Docker / OrbStack ports stay in Other listeners until v1.0 maps them (AGENTS.md §14).
    public static let keepBundles: Set<String> = [
        "Postgres.app",
        "DBngin.app",
        "Herd.app",
        "Docker.app",
        "OrbStack.app",
        "Rancher Desktop.app",
    ]

    public static func isAppListener(_ listener: Listener) -> Bool {
        isAppExecutable(listener.executablePath)
    }

    /// True when `path` is inside a `.app` bundle that isn't nested in a `.framework`
    /// (python.org and Homebrew Python run `…/Python.framework/…/Python.app/…`) and isn't kept.
    public static func isAppExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        for component in path.split(separator: "/") {
            if component.hasSuffix(".framework") { return false }
            if component.hasSuffix(".app") {
                return !keepBundles.contains(String(component))
            }
        }
        return false
    }
}
