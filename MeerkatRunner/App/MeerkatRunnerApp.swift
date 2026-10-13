import AppKit
import Registry
import Store
import Supervisor
import SwiftUI

@main
struct MeerkatRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(appDelegate.registry)
                .environment(appDelegate.addServer)
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
                .environment(appDelegate.addServer)
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
    let registry: ServerRegistry = {
        let paths = StorePaths.standard
        return ServerRegistry(
            store: ProjectStore(paths: paths),
            supervisor: ProcessSupervisor(logsDirectory: paths.logsDirectory, runtimeFile: paths.runtimeFile)
        )
    }()
    let addServer = AddServerModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await registry.start() }
    }

    /// Settings › On quit (§6.7): stop managed servers (default), leave them running, or ask.
    /// Servers left running are re-adopted on the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard registry.hasManagedServers else { return .terminateNow }
        let raw = UserDefaults.standard.string(forKey: QuitBehaviour.defaultsKey) ?? ""
        switch QuitBehaviour(rawValue: raw) ?? .stopManaged {
        case .leaveRunning:
            return .terminateNow
        case .ask:
            let alert = NSAlert()
            alert.messageText = "Stop the servers Runner started?"
            alert.informativeText = "Servers you leave running keep going; Runner picks them up again next time it opens."
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Leave Running")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: return .terminateNow
            default: return .terminateCancel
            }
        case .stopManaged:
            break
        }
        Task {
            await registry.stopAllManaged()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
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
