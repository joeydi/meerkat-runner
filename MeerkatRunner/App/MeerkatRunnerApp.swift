import AppKit
import Models
import Registry
import Store
import Supervisor
import SwiftUI
import UserNotifications

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
    /// SwiftUI's own identifier for the `Settings` scene's window.
    static let settings = "com_apple_SwiftUI_Settings_window"
}

/// Brings a window Runner just opened in front of the app you were using. On macOS 14+
/// `NSApp.activate()` is only a request, and a menu bar app that isn't already active can be
/// refused, which left windows (notably Settings) opening behind the frontmost app.
@MainActor
enum WindowFront {
    /// `id` is a `WindowID`; SwiftUI window identifiers start with it (e.g. `logs-AppWindow-2`).
    static func raise(_ id: String) {
        // The window exists once SwiftUI has processed the open request.
        DispatchQueue.main.async {
            guard let window = NSApp.orderedWindows.first(where: {
                $0.isVisible && ($0.identifier?.rawValue.hasPrefix(id) ?? false)
            }) else { return }
            window.orderFrontRegardless()
            window.makeKey()
            NSApp.activate()
        }
    }
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

    let crashNotifier = CrashNotifier()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting unit tests: don't scan, touch the Keychain or capture the shell environment.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        crashNotifier.install()
        // Global shortcut to open the menu (§7); none until the user records one in Settings.
        HotKeyCenter.shared.onPress = { MenuBarToggle.toggle() }
        try? HotKeyCenter.shared.register(HotKey.load())
        registry.onCrash = { [crashNotifier] project, exitCode in
            crashNotifier.post(project: project, exitCode: exitCode)
        }
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

/// Lets code outside a view (notification clicks) open SwiftUI windows. Set by the always-present
/// menu bar label.
@MainActor
enum WindowOpener {
    static var openWindow: OpenWindowAction?

    static func showLogs(for projectID: UUID) {
        NSApp.activate()
        openWindow?(id: WindowID.logs, value: projectID)
        WindowFront.raise(WindowID.logs)
    }
}

/// Crash notifications (§6.8): "<name> stopped unexpectedly — Exited with code 1", action View Logs.
@MainActor
final class CrashNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let category = "crash"
    nonisolated static let viewLogsAction = "view-logs"

    private var authorizationRequested = false

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let viewLogs = UNNotificationAction(identifier: Self.viewLogsAction, title: "View Logs", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [viewLogs], intentIdentifiers: []),
        ])
    }

    func post(project: Project, exitCode: Int32) {
        // Ask once, on the first crash, rather than at launch.
        let ask = !authorizationRequested
        authorizationRequested = true
        let title = "\(project.name) stopped unexpectedly"
        let body = "Exited with code \(exitCode)"
        let projectID = project.id.uuidString
        Task.detached { await Self.deliver(title: title, body: body, projectID: projectID, askFirst: ask) }
    }

    private nonisolated static func deliver(title: String, body: String, projectID: String, askFirst: Bool) async {
        let center = UNUserNotificationCenter.current()
        if askFirst { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = ["projectID": projectID]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let raw = response.notification.request.content.userInfo["projectID"] as? String,
              let projectID = UUID(uuidString: raw)
        else { return }
        await MainActor.run { WindowOpener.showLogs(for: projectID) }
    }

    /// Show crash notifications even while Runner is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Menu bar icon with the running-count badge (hidden at 0).
struct MenuBarLabel: View {
    let registry: ServerRegistry
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // TODO: replace `server.rack` with the template meerkat glyph once artwork exists (DESIGN.md §2.4).
        let count = registry.runningCount
        Group {
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
        .onAppear { WindowOpener.openWindow = openWindow }
    }
}
