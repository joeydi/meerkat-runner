import AppKit
import Registry
import SwiftUI

@main
struct MeerkatRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(appDelegate.registry)
        } label: {
            MenuBarLabel(registry: appDelegate.registry)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appDelegate.registry)
        }

        // Sheets live in their own windows, not inside the popover: MenuBarExtra(.window) closes when
        // focus moves and doesn't dismiss cleanly with a sheet open (AGENTS.md §14).
        Window("Add Server", id: WindowID.addServer) {
            AddServerSheet()
                .environment(appDelegate.registry)
        }
        .windowResizability(.contentSize)

        WindowGroup("Review Changes", id: WindowID.reapproval, for: UUID.self) { $projectID in
            ReapprovalSheet(projectID: projectID)
                .environment(appDelegate.registry)
        }
        .windowResizability(.contentSize)

        WindowGroup("Logs", id: WindowID.logs, for: UUID.self) { $projectID in
            LogWindow(projectID: projectID)
                .environment(appDelegate.registry)
        }
        .defaultSize(width: 720, height: 440)
    }
}

enum WindowID {
    static let addServer = "add-server"
    static let reapproval = "reapproval"
    static let logs = "logs"
}

enum MeerkatLinks {
    /// TODO(AGENTS.md §13 Q4): Meerkat waitlist URL for the footer and empty state.
    static let waitlist: URL? = nil
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let registry = ServerRegistry()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await registry.start() }
    }

    // TODO(v0.2): "On quit" setting (§6.7) — stop managed servers (default) / leave running / ask.
}

/// Menu bar icon with the running-count badge (hidden at 0).
struct MenuBarLabel: View {
    let registry: ServerRegistry

    var body: some View {
        // TODO: replace `server.rack` with the template meerkat glyph once artwork exists (DESIGN.md §2.4).
        let count = registry.runningCount
        if count > 0 {
            HStack(spacing: 2) {
                Image(systemName: "server.rack")
                Text("\(count)")
            }
            .accessibilityLabel("Meerkat Runner, \(count) running")
        } else {
            Image(systemName: "server.rack")
                .accessibilityLabel("Meerkat Runner")
        }
    }
}
