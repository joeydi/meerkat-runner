import AppKit
import Models
import Registry
import Scanner
import SwiftUI

/// A registered project row (DESIGN.md §3 `ServerRow`).
struct ServerRow: View {
    let row: ProjectRow
    /// Keyboard-selected in the menu: accent fill, white text, actions shown.
    var isSelected = false
    @Environment(ServerRegistry.self) private var registry
    @Environment(\.openWindow) private var openWindow
    @State private var isHovering = false

    private var actions: ProjectActions { ProjectActions(registry: registry, openWindow: openWindow) }
    private var showsActions: Bool { isHovering || isSelected }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(kind: StatusDot.Kind(row.state))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.project.name).font(Tokens.Font.rowName).lineLimit(1)
                Text(meta)
                    .font(Tokens.Font.meta)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                    .lineLimit(1)
            }
            // Badges give way before the meta line truncates (DESIGN.md §3).
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.vertical, 7)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .rowBackground(isSelected: isSelected, isHovering: isHovering)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions { accessibilityActionButtons }
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
        var text = "\(row.project.name), \(state), \(meta)"
        if case .running(let managed, let listeners, _) = row.state {
            if !managed { text += ", started in Terminal" }
            if listeners.contains(where: \.isLANVisible) { text += ", visible on the local network" }
        }
        return text
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .running(let managed, let listeners, _):
            HStack(spacing: 4) {
                if showsActions {
                    if row.project.port != nil {
                        IconButton(symbol: "arrow.up.forward.square", label: "Open in Browser") { actions.open(row) }
                    }
                    if managed {
                        IconButton(symbol: "text.alignleft", label: "Show Logs") { actions.showLogs(row) }
                    } else {
                        IconButton(symbol: "arrow.clockwise", label: "Restart in Runner") { actions.restart(row) }
                    }
                    IconButton(symbol: "stop.fill", label: "Stop") { actions.stop(row) }
                } else {
                    if listeners.contains(where: \.isLANVisible) {
                        LANIndicator()
                    }
                    if !managed {
                        Badge(text: "Started in Terminal", style: .neutral, symbol: "terminal")
                    }
                }
            }
        case .starting, .stopping:
            HStack(spacing: 4) {
                if showsActions, registry.managed[row.id] != nil {
                    IconButton(symbol: "text.alignleft", label: "Show Logs") { actions.showLogs(row) }
                }
                ProgressView().controlSize(.small)
            }
        case .stopped:
            HStack(spacing: 4) {
                if showsActions {
                    IconButton(symbol: "text.alignleft", label: "Show Logs") { actions.showLogs(row) }
                }
                IconButton(symbol: "play.fill", label: "Start") { actions.start(row) }
            }
        case .crashed(let code, _):
            HStack(spacing: 4) {
                Text("Exited (\(code))")
                    .font(Tokens.Font.meta)
                    .foregroundStyle(isSelected ? Color.white : Tokens.Colors.errorText)
                IconButton(symbol: "text.alignleft", label: "View Logs") { actions.showLogs(row) }
                IconButton(symbol: "play.fill", label: "Start") { actions.start(row) }
            }
        case .needsReapproval:
            Button("Review") { actions.review(row) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        switch row.state {
        case .running(let managed, _, _):
            Button("Open in Browser") { actions.open(row) }.disabled(row.project.port == nil)
            Button("Copy URL") { actions.copyURL(row) }.disabled(row.project.port == nil)
            if managed { Button("Show Logs") { actions.showLogs(row) } }
            Button(managed ? "Restart" : "Restart in Runner") { actions.restart(row) }
            Button("Stop") { actions.stop(row) }
        case .stopped, .crashed:
            Button("Start") { actions.start(row) }
            Button("Show Logs") { actions.showLogs(row) }
        case .needsReapproval:
            Button("Review…") { actions.review(row) }
        case .starting, .stopping:
            EmptyView()
        }
        Divider()
        Button("Reveal in Finder") { actions.revealInFinder(row) }
        Button("Remove from Runner…") { actions.confirmRemove(row) }
    }

    /// The row's actions for VoiceOver (DESIGN.md §6).
    @ViewBuilder
    private var accessibilityActionButtons: some View {
        switch row.state {
        case .running(let managed, _, _):
            if row.project.port != nil { Button("Open in Browser") { actions.open(row) } }
            if managed {
                Button("Show Logs") { actions.showLogs(row) }
            } else {
                Button("Restart in Runner") { actions.restart(row) }
            }
            Button("Stop") { actions.stop(row) }
        case .stopped, .crashed:
            Button("Start") { actions.start(row) }
            Button("Show Logs") { actions.showLogs(row) }
        case .needsReapproval:
            Button("Review") { actions.review(row) }
        case .starting, .stopping:
            EmptyView()
        }
    }
}

/// An unmatched listener, one row per (process, port). View-only: **no Stop, anywhere**
/// (AGENTS.md §1, DESIGN.md §3 `OtherListenerRow`).
struct OtherListenerRow: View {
    let group: ListenerGroup
    var isSelected = false
    @Environment(AddServerModel.self) private var addServerModel
    @Environment(\.openWindow) private var openWindow
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(kind: .other)
            HStack(spacing: 0) {
                Text(group.processName)
                if let cwd = group.cwd, cwd != "/" {
                    Text(" — \(Format.abbreviatingHome(cwd))")
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                        .truncationMode(.middle)
                }
            }
            .font(.body)
            .lineLimit(1)
            Spacer(minLength: 8)
            if isHovering || isSelected {
                IconButton(symbol: "arrow.up.forward.square", label: "Open in Browser") { open() }
                IconButton(symbol: "doc.on.doc", label: "Copy URL") { copyURL() }
                if group.cwd != nil {
                    IconButton(symbol: "folder", label: "Reveal Folder") { revealFolder() }
                }
                if canAddAsServer {
                    IconButton(symbol: "plus.square", label: "Add as Server…") { addAsServer() }
                }
            } else if group.isLANVisible {
                LANIndicator()
            }
            Text(":\(String(group.port))")
                .font(Tokens.Font.port)
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .rowBackground(isSelected: isSelected, isHovering: isHovering)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Open in Browser") { open() }
        .accessibilityAction(named: "Copy URL") { copyURL() }
        .accessibilityAction(named: "Add as Server") { if canAddAsServer { addAsServer() } }
    }

    private var accessibilityText: String {
        var text = "\(group.processName), port \(group.port)"
        if let cwd = group.cwd { text += ", in \(Format.abbreviatingHome(cwd))" }
        if group.isLANVisible { text += ", visible on the local network" }
        return text
    }

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
        URLActions.open(port: group.port)
    }

    private func copyURL() {
        URLActions.copy(port: group.port)
    }

    private func revealFolder() {
        guard let cwd = group.cwd else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }

    private func copy(_ string: String) {
        URLActions.copy(text: string)
    }
}
