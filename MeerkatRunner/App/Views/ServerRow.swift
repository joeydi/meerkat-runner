import AppKit
import Models
import Registry
import Scanner
import SwiftUI

/// A registered project row (DESIGN.md §3 `ServerRow`).
struct ServerRow: View {
    let row: ProjectRow
    @Environment(ServerRegistry.self) private var registry
    @Environment(\.openWindow) private var openWindow
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(kind: StatusDot.Kind(row.state))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.project.name).font(Tokens.Font.rowName).lineLimit(1)
                Text(meta).font(Tokens.Font.meta).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 7)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .background(isHovering ? Tokens.Colors.fillControl : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if row.state == .needsReapproval {
                Button("Review…") { review() }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: row.project.path)
            }
            Divider()
            Button("Remove from Runner…") { confirmRemove() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Running: `Framework · localhost:port · uptime`. Stopped: `Framework · command · :port`.
    private var meta: String {
        var parts: [String] = []
        if let framework = row.framework { parts.append(framework) }
        switch row.state {
        case .running(_, _, let since):
            if let port = row.project.port { parts.append("localhost:\(port)") }
            parts.append(Format.uptime(since: since))
        default:
            parts.append(row.project.command.displayString)
            if let port = row.project.port { parts.append(":\(port)") }
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        let state: String = switch row.state {
        case .running: "running"
        case .starting: "starting"
        case .stopping: "stopping"
        case .stopped: "stopped"
        case .crashed(let code, _): "exited with code \(code)"
        case .needsReapproval: "needs approval"
        }
        return "\(row.project.name), \(state), \(meta)"
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .running(let managed, let listeners, _):
            HStack(spacing: 4) {
                if isHovering {
                    if row.project.port != nil {
                        IconButton(symbol: "arrow.up.forward.square", label: "Open in Browser") { open() }
                    }
                    if managed {
                        IconButton(symbol: "text.alignleft", label: "Show Logs") { showLogs() }
                        IconButton(symbol: "stop.fill", label: "Stop") { stop() }
                    } else {
                        IconButton(symbol: "arrow.clockwise", label: "Restart in Runner") { restartInRunner() }
                        IconButton(symbol: "stop.fill", label: "Stop") { confirmExternalStop() }
                    }
                } else {
                    if listeners.contains(where: \.isLANVisible) {
                        Badge(text: "LAN visible", style: .warning)
                            .help("Listening on all network interfaces. Other devices on your network can reach it.")
                    }
                    if !managed {
                        Badge(text: "Started in Terminal", style: .neutral, symbol: "terminal")
                    }
                }
            }
        case .starting, .stopping:
            HStack(spacing: 4) {
                if isHovering, registry.managed[row.id] != nil {
                    IconButton(symbol: "text.alignleft", label: "Show Logs") { showLogs() }
                }
                ProgressView().controlSize(.small)
            }
        case .stopped:
            HStack(spacing: 4) {
                if isHovering {
                    IconButton(symbol: "text.alignleft", label: "Show Logs") { showLogs() }
                }
                IconButton(symbol: "play.fill", label: "Start") { start() }
            }
        case .crashed(let code, _):
            HStack(spacing: 4) {
                Text("Exited (\(code))").font(Tokens.Font.meta).foregroundStyle(Tokens.Colors.errorText)
                IconButton(symbol: "text.alignleft", label: "View Logs") { showLogs() }
                IconButton(symbol: "play.fill", label: "Start") { start() }
            }
        case .needsReapproval:
            Button("Review") { review() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    /// Always through the registry → approval gate; a changed script opens the review window instead.
    private func start() {
        let id = row.project.id
        let name = row.project.name
        Task {
            do {
                try await registry.startProject(id)
            } catch ServerRegistry.StartError.needsApproval {
                review()
            } catch ServerRegistry.StartError.failed(let message) {
                Alerts.show("Couldn't start \(name)", message)
            } catch {}
        }
    }

    /// Terminal-started servers confirm first; the terminal itself is never touched (DESIGN.md §5).
    private func confirmExternalStop() {
        let alert = NSAlert()
        alert.messageText = "Stop \(row.project.name)?"
        alert.informativeText = "It was started in Terminal. The terminal stays open."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        stop()
    }

    /// Stops the terminal-started server, waits for its port, then starts the saved command in Runner.
    private func restartInRunner() {
        let id = row.project.id
        let name = row.project.name
        Task {
            do {
                try await registry.restartInRunner(id)
            } catch ServerRegistry.StopError.portStillInUse(let port) {
                Alerts.show("Couldn't restart \(name)", "Port \(port) didn't free up within 10 seconds, so Runner didn't start it.")
            } catch ServerRegistry.StopError.restartFailed(.needsApproval) {
                review()
            } catch ServerRegistry.StopError.restartFailed(.failed(let message)) {
                Alerts.show("Couldn't start \(name)", message)
            } catch ServerRegistry.StopError.failed(let message) {
                Alerts.show("Couldn't stop \(name)", message)
            } catch {}
        }
    }

    private func stop() {
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

    private func review() {
        NSApp.activate()
        openWindow(id: WindowID.reapproval, value: row.project.id)
    }

    /// Removing only forgets the project; its folder is never touched (AGENTS.md §1 non-goals).
    private func confirmRemove() {
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

    private func open() {
        guard let port = row.project.port, let url = Format.localURL(port: port) else { return }
        NSWorkspace.shared.open(url)
    }

    private func showLogs() {
        NSApp.activate()
        openWindow(id: WindowID.logs, value: row.project.id)
    }
}

/// An unmatched listener, one row per (process, port). View-only: **no Stop, anywhere**
/// (AGENTS.md §1, DESIGN.md §3 `OtherListenerRow`).
struct OtherListenerRow: View {
    let group: ListenerGroup
    @Environment(AddServerModel.self) private var addServerModel
    @Environment(\.openWindow) private var openWindow
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(kind: .other)
            HStack(spacing: 0) {
                Text(group.processName).foregroundStyle(.primary)
                if let cwd = group.cwd, cwd != "/" {
                    Text(" — \(Format.abbreviatingHome(cwd))")
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
            }
            .font(.body)
            .lineLimit(1)
            Spacer(minLength: 8)
            if isHovering {
                IconButton(symbol: "arrow.up.forward.square", label: "Open in Browser") { open() }
                IconButton(symbol: "doc.on.doc", label: "Copy URL") { copyURL() }
                if group.cwd != nil {
                    IconButton(symbol: "folder", label: "Reveal Folder") { revealFolder() }
                }
                if canAddAsServer {
                    IconButton(symbol: "plus.square", label: "Add as Server…") { addAsServer() }
                }
            } else if group.isLANVisible {
                Badge(text: "LAN visible", style: .warning)
                    .help("Listening on all network interfaces. Other devices on your network can reach it.")
            }
            Text(":\(String(group.port))").font(Tokens.Font.port).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .background(isHovering ? Tokens.Colors.fillControl : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in Browser") { open() }
            Button("Copy URL") { copyURL() }
            if group.cwd != nil {
                Button("Reveal in Finder") { revealFolder() }
            }
            if canAddAsServer {
                Button("Add as Server…") { addAsServer() }
            }
            Divider()
            Button("Copy PID") { copy(String(group.pid)) }
        }
        .help("PID \(group.pid)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "Open in Browser") { open() }
        .accessibilityAction(named: "Copy URL") { copyURL() }
    }

    private var accessibilityText: String {
        var text = "\(group.processName), port \(group.port)"
        if let cwd = group.cwd { text += ", in \(Format.abbreviatingHome(cwd))" }
        if group.isLANVisible { text += ", visible on the local network" }
        return text
    }

    private var url: URL? { Format.localURL(port: group.port) }

    /// Only offer for a real project-looking folder: not `/` or the home folder itself.
    private var canAddAsServer: Bool {
        guard let cwd = group.cwd else { return false }
        return cwd != "/" && cwd != NSHomeDirectory()
    }

    /// Pre-fills the Add window with the listener's working directory (AGENTS.md §9.1).
    private func addAsServer() {
        guard let cwd = group.cwd else { return }
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

    private func open() {
        if let url { NSWorkspace.shared.open(url) }
    }

    private func copyURL() {
        if let url { copy(url.absoluteString) }
    }

    private func revealFolder() {
        guard let cwd = group.cwd else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
