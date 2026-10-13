import AppKit
import Models
import Registry
import Scanner
import SwiftUI

/// The actions a project row offers, shared by its buttons, context menu, VoiceOver actions and the
/// menu's keyboard shortcuts (DESIGN.md §5). Every start goes through the registry → approval gate.
@MainActor
struct ProjectActions {
    let registry: ServerRegistry
    let openWindow: OpenWindowAction

    /// Return: open a running server, start a stopped or crashed one, review one that needs approval.
    func primary(_ row: ProjectRow) {
        switch row.state {
        case .running: open(row)
        case .stopped, .crashed: start(row)
        case .needsReapproval: review(row)
        case .starting, .stopping: break
        }
    }

    /// The row's action buttons, in order (shared by `ServerRow` and the menu's Tab order).
    static func rowActions(for row: ProjectRow, registry: ServerRegistry) -> [RowAction] {
        RowAction.forProject(
            state: row.state, hasPort: row.project.port != nil, hasLogs: registry.managed[row.id] != nil
        )
    }

    func perform(_ action: RowAction, on row: ProjectRow) {
        switch action {
        case .open: open(row)
        case .logs: showLogs(row)
        case .restart: restart(row)
        case .stop: stop(row)
        case .start: start(row)
        case .review: review(row)
        case .copyURL: copyURL(row)
        case .revealFolder: revealInFinder(row)
        case .addAsServer: break
        }
    }

    func start(_ row: ProjectRow) {
        let id = row.project.id
        let name = row.project.name
        Task {
            do {
                try await registry.startProject(id)
            } catch ServerRegistry.StartError.needsApproval {
                review(id)
            } catch ServerRegistry.StartError.failed(let message) {
                Alerts.show("Couldn't start \(name)", message)
            } catch {}
        }
    }

    /// Runner-launched servers stop straight away; terminal-started ones confirm first, and the terminal
    /// itself is never touched (DESIGN.md §5).
    func stop(_ row: ProjectRow) {
        guard row.state.isRunning || row.state == .starting else { return }
        if case .running(let managed, _, _) = row.state, !managed {
            let alert = NSAlert()
            alert.messageText = "Stop \(row.project.name)?"
            alert.informativeText = "It was started in Terminal. The terminal stays open."
            alert.addButton(withTitle: "Stop")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let id = row.project.id
        let name = row.project.name
        Task {
            do {
                try await registry.stopProject(id)
            } catch ServerRegistry.StopError.failed(let message) {
                Alerts.show("Couldn't stop \(name)", message)
            } catch {}
        }
    }

    /// ⌘R / ↻: restart a Runner-managed server, Restart in Runner for a terminal-started one, or start.
    func restart(_ row: ProjectRow) {
        let id = row.project.id
        let name = row.project.name
        Task {
            do {
                try await registry.restart(id)
            } catch ServerRegistry.StopError.portStillInUse(let port) {
                Alerts.show("Couldn't restart \(name)", "Port \(port) didn't free up within 10 seconds, so Runner didn't start it.")
            } catch ServerRegistry.StopError.restartFailed(.needsApproval) {
                review(id)
            } catch ServerRegistry.StopError.restartFailed(.failed(let message)) {
                Alerts.show("Couldn't start \(name)", message)
            } catch ServerRegistry.StopError.failed(let message) {
                Alerts.show("Couldn't stop \(name)", message)
            } catch {}
        }
    }

    func review(_ row: ProjectRow) { review(row.project.id) }

    func review(_ projectID: UUID) {
        NSApp.activate()
        openWindow(id: WindowID.reapproval, value: projectID)
    }

    func showLogs(_ row: ProjectRow) {
        NSApp.activate()
        openWindow(id: WindowID.logs, value: row.project.id)
    }

    func open(_ row: ProjectRow) {
        if let port = row.project.port { URLActions.open(port: port) }
    }

    func copyURL(_ row: ProjectRow) {
        if let port = row.project.port { URLActions.copy(port: port) }
    }

    func revealInFinder(_ row: ProjectRow) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: row.project.path)
    }

    /// Removing only forgets the project; its folder is never touched (AGENTS.md §1 non-goals).
    func confirmRemove(_ row: ProjectRow) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(row.project.name)” from Runner?"
        alert.informativeText = "Its folder and files aren't touched. You can add it again later."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = row.project.id
        Task { try? await registry.remove(projectID: id) }
    }
}

/// The actions an other-listener row offers. View-only: there is no Stop (AGENTS.md §1).
@MainActor
struct ListenerActions {
    let addServerModel: AddServerModel
    let openWindow: OpenWindowAction

    static func rowActions(for group: ListenerGroup) -> [RowAction] {
        RowAction.forListener(hasFolder: group.cwd != nil, canAddAsServer: canAddAsServer(group))
    }

    /// Only offer for a real project-looking folder: not `/` or the home folder itself.
    static func canAddAsServer(_ group: ListenerGroup) -> Bool {
        guard let cwd = group.cwd else { return false }
        return cwd != "/" && cwd != NSHomeDirectory()
    }

    func perform(_ action: RowAction, on group: ListenerGroup) {
        switch action {
        case .open:
            URLActions.open(port: group.port)
        case .copyURL:
            URLActions.copy(port: group.port)
        case .revealFolder:
            if let cwd = group.cwd { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
        case .addAsServer:
            addAsServer(group)
        case .logs, .restart, .stop, .start, .review:
            break
        }
    }

    /// Pre-fills the Add window with the listener's working directory (AGENTS.md §9.1).
    private func addAsServer(_ group: ListenerGroup) {
        guard Self.canAddAsServer(group), let cwd = group.cwd else { return }
        let listener = group.primary
        let running = AddServerModel.RunningServer(
            argv: listener.argv,
            port: group.port,
            framework: ListenerClassifier.classify(executablePath: listener.executablePath, argv: listener.argv)
        )
        addServerModel.load(URL(fileURLWithPath: cwd, isDirectory: true), running: running)
        NSApp.activate()
        openWindow(id: WindowID.addServer)
    }
}

extension ServerState {
    var isCrashed: Bool {
        if case .crashed = self { return true }
        return false
    }
}

/// Opening and copying `http://localhost:<port>` (always `localhost`, never `127.0.0.1`; AGENTS.md §14).
enum URLActions {
    @MainActor
    static func open(port: Int) {
        if let url = Format.localURL(port: port) { NSWorkspace.shared.open(url) }
    }

    @MainActor
    static func copy(port: Int) {
        if let url = Format.localURL(port: port) { copy(text: url.absoluteString) }
    }

    @MainActor
    static func copy(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Row selection

private struct RowSelectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the keyboard-selected row: it fills with the accent colour and its text and glyphs
    /// turn white (DESIGN.md §3 `ServerRow` "Selection").
    var isRowSelected: Bool {
        get { self[RowSelectedKey.self] }
        set { self[RowSelectedKey.self] = newValue }
    }
}

extension View {
    /// Row background: accent when selected, `fillControl` on hover, otherwise clear.
    func rowBackground(isSelected: Bool, isHovering: Bool) -> some View {
        background(
            isSelected ? Color.accentColor : (isHovering ? Tokens.Colors.fillControl : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .environment(\.isRowSelected, isSelected)
    }
}
