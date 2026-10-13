import AppKit
import Models
import Scanner
import SwiftUI

/// A registered project row (DESIGN.md §3 `ServerRow`).
struct ServerRow: View {
    let row: ProjectRow
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
                    IconButton(symbol: "arrow.up.forward.square", label: "Open in Browser") { open() }
                    if managed {
                        IconButton(symbol: "text.alignleft", label: "Show Logs") { showLogs() }
                    } else {
                        IconButton(symbol: "arrow.clockwise", label: "Restart in Runner") {
                            // TODO(v0.2): Restart in Runner (§6.5).
                        }
                    }
                    IconButton(symbol: "stop.fill", label: "Stop") {
                        // TODO(v0.2): stop; terminal-started servers confirm first (DESIGN.md §5).
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
            ProgressView().controlSize(.small)
        case .stopped:
            IconButton(symbol: "play.fill", label: "Start") {
                // TODO(v0.2): start through ApprovalGate.
            }
        case .crashed(let code, _):
            HStack(spacing: 4) {
                Text("Exited (\(code))").font(Tokens.Font.meta).foregroundStyle(Tokens.Colors.errorText)
                IconButton(symbol: "play.fill", label: "Start") {
                    // TODO(v0.2)
                }
            }
        case .needsReapproval:
            Button("Review") { openWindow(id: WindowID.reapproval, value: row.project.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
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
