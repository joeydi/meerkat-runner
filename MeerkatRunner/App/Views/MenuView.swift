import AppKit
import Models
import Registry
import SwiftUI

/// The dropdown (AGENTS.md §9.1, DESIGN.md §4.1). Fixed 360 pt wide.
struct MenuView: View {
    @Environment(ServerRegistry.self) private var registry
    @Environment(AddServerModel.self) private var addServerModel
    @Environment(\.openWindow) private var openWindow
    @State private var filter = ""
    @State private var showAllOther = false
    /// Measured height of the section list. A bare ScrollView has no ideal height, and
    /// MenuBarExtra(.window) sizes itself to ideal height, so the list would collapse to zero.
    @State private var listHeight: CGFloat = 0

    /// Other listeners shown before "Show N more" (DESIGN.md §4.1).
    private static let otherListenerLimit = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            if totalRowCount >= 6 {
                filterField
            }
            if registry.storeIntegrityWarning {
                integrityWarning
            }
            if isEmpty {
                emptyState
            } else {
                ScrollView {
                    sections
                        .padding(.horizontal, 6)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                // Grow with the content up to the cap (DESIGN.md §2.3), then scroll.
                .frame(height: min(listHeight, Tokens.popoverMaxHeight))
            }
            Divider()
            footer
        }
        .frame(width: Tokens.popoverWidth)
        .onAppear { registry.setPolling(menuOpen: true) }
        .onDisappear {
            registry.setPolling(menuOpen: false)
            showAllOther = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Servers").font(Tokens.Font.header)
                if !summary.isEmpty {
                    Text(summary).font(Tokens.Font.meta).foregroundStyle(.secondary)
                }
            }
            Spacer()
            IconButton(symbol: "plus", label: "Add Server from Folder…", size: .header) { addServer() }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.top, 12)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .padding(.leading, 16)
    }

    /// `3 running · 1 stopped · 2 other`, omitting zero counts.
    private var summary: String {
        [
            (registry.runningRows.count, "running"),
            (registry.stoppedRows.count, "stopped"),
            (registry.visibleOtherListeners.count, "other"),
        ]
        .filter { $0.0 > 0 }
        .map { "\($0.0) \($0.1)" }
        .joined(separator: " · ")
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Filter by name or port", text: $filter)
                .textFieldStyle(.plain)
                .font(Tokens.Font.bodySmall)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Tokens.Colors.fillControl, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Sections

    private var totalRowCount: Int { registry.projects.count + registry.visibleOtherListeners.count }
    private var isEmpty: Bool { totalRowCount == 0 }

    @ViewBuilder
    private var sections: some View {
        let running = registry.runningRows.filter { matchesRow($0) }
        let needsApproval = registry.needsApprovalRows.filter { matchesRow($0) }
        let stopped = registry.stoppedRows.filter { matchesRow($0) }
        let other = registry.visibleOtherListeners.filter { matchesListener($0) }
        // While filtering, show every match; otherwise collapse to the first few.
        let collapsed = filter.isEmpty && !showAllOther && other.count > Self.otherListenerLimit
        let shownOther = collapsed ? Array(other.prefix(Self.otherListenerLimit)) : other
        let groups: [(String, AnyView)] = [
            ("Running", AnyView(ForEach(running) { ServerRow(row: $0) })),
            ("Needs approval", AnyView(ForEach(needsApproval) { ServerRow(row: $0) })),
            ("Stopped", AnyView(ForEach(stopped) { ServerRow(row: $0) })),
            ("Other listeners", AnyView(VStack(spacing: 0) {
                ForEach(shownOther) { OtherListenerRow(group: $0) }
                if collapsed {
                    ShowMoreRow(count: other.count - shownOther.count) { showAllOther = true }
                }
            })),
        ]
        let counts = [running.count, needsApproval.count, stopped.count, other.count]
        let visible = groups.indices.filter { counts[$0] > 0 }

        // TODO(v0.3): keyboard selection (§9.1, DESIGN.md §5).
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visible, id: \.self) { index in
                if index != visible.first {
                    Divider().padding(.horizontal, 10).padding(.vertical, 6)
                }
                SectionHeader(title: groups[index].0)
                groups[index].1
            }
        }
        .padding(.vertical, 4)
    }

    private func matchesRow(_ row: ProjectRow) -> Bool {
        guard !filter.isEmpty else { return true }
        let haystack = [row.project.name, row.framework ?? "", row.project.path, row.project.port.map(String.init) ?? ""]
        return haystack.contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    private func matchesListener(_ group: ListenerGroup) -> Bool {
        guard !filter.isEmpty else { return true }
        let haystack = [group.processName, group.cwd ?? "", String(group.port)]
        return haystack.contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    // MARK: - Integrity warning (AGENTS.md §3 Storage)

    private var integrityWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tokens.Colors.warningText)
                .accessibilityHidden(true)
            Text("Runner's saved projects were changed outside the app, so every approval was cleared. Review each project before it runs.")
                .font(Tokens.Font.meta)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("OK") { registry.dismissStoreIntegrityWarning() }
                .controlSize(.small)
        }
        .padding(10)
        .background(Tokens.Colors.warningFill, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("No dev servers running").font(Tokens.Font.rowName)
            Text("Add a project folder and Runner will find how it starts.")
                .font(Tokens.Font.meta)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            Button("Add Server from Folder…") { addServer() }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            meerkatLink("Monitor these sites once they're live → Meerkat")
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            FooterRow(title: "Add Server from Folder…", shortcut: "⌘N") { addServer() }
                .keyboardShortcut("n", modifiers: .command)
            FooterRow(title: "Stop All Managed Servers") {
                // TODO(v0.2): stop managed servers only; terminal-started ones are excluded.
            }
            .disabled(!registry.runningRows.contains { $0.state.isManaged })
            .help("Stops servers Runner started. Servers started in Terminal are left running.")
            meerkatLink("Made by Meerkat")
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func meerkatLink(_ title: String) -> some View {
        if let url = MeerkatLinks.waitlist {
            Link(title, destination: url).font(Tokens.Font.meta).foregroundStyle(.tertiary)
        } else {
            Text(title).font(Tokens.Font.meta).foregroundStyle(.tertiary)
        }
    }

    private func addServer() {
        addServerModel.requestFolderPicker()
        NSApp.activate()
        openWindow(id: WindowID.addServer)
    }
}

private struct ShowMoreRow: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button("Show \(count) more", action: action)
            .buttonStyle(.plain)
            .font(Tokens.Font.meta)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.leading, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct FooterRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    // Plain buttons don't dim when disabled; do it explicitly.
                    .foregroundStyle(isEnabled ? HierarchicalShapeStyle.primary : .tertiary)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(
                isHovering && isEnabled ? Tokens.Colors.fillControl : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
