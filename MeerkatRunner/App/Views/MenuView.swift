import AppKit
import Models
import Registry
import SwiftUI

/// The dropdown (AGENTS.md §9.1, DESIGN.md §4.1). Fixed 360 pt wide.
struct MenuView: View {
    @Environment(ServerRegistry.self) private var registry
    @Environment(AddServerModel.self) private var addServerModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var filter = ""
    @State private var showAllOther = false
    /// Keyboard focus (DESIGN.md §5): a header button, the filter, a row or one of its actions, Show
    /// more, or a footer item. Hover is separate and never moves it.
    @State private var focus: MenuFocus?
    @FocusState private var filterFocused: Bool
    /// Measured height of the section list. A bare ScrollView has no ideal height, and
    /// MenuBarExtra(.window) sizes itself to ideal height, so the list would collapse to zero.
    @State private var listHeight: CGFloat = 0

    /// Other listeners shown before "Show N more" (DESIGN.md §4.1).
    private static let otherListenerLimit = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsFilter {
                filterField
            }
            if registry.storeIntegrityWarning {
                integrityWarning
            }
            if isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        sections
                            .padding(.horizontal, 6)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    }
                    // Grow with the content up to the cap (DESIGN.md §2.3), then scroll.
                    .frame(height: min(listHeight, Tokens.popoverMaxHeight))
                    .onChange(of: focus) {
                        if let row = focus?.rowID {
                            proxy.scrollTo(row)
                        } else if focus == .showMore {
                            proxy.scrollTo(MenuFocus.showMore)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: Tokens.popoverWidth)
        .background(KeyEventMonitor(handler: { handleKey($0) }, onWindow: { MenuBarToggle.menuWindow = $0 }))
        // A focused control that disappears (stopped, filtered away, disabled) hands focus to its
        // nearest neighbour so Tab and Return keep working.
        .onChange(of: focusOrder) { previous, current in
            focus = MenuNavigation.recover(focus, previous: previous, current: current)
        }
        .onChange(of: filterFocused) {
            if filterFocused, focus?.rowID == nil {
                focus = .filter
            } else if !filterFocused, focus == .filter {
                focus = nil
            }
        }
        .onAppear { registry.setPolling(menuOpen: true) }
        .onDisappear {
            registry.setPolling(menuOpen: false)
            showAllOther = false
            focus = nil
            filter = ""
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
            IconButton(
                symbol: "plus", label: "Add Server from Folder…", size: .header, isFocused: focus == .addServer
            ) { addServer() }
            // A button rather than SettingsLink, so Runner is activated and the window comes to the front.
            IconButton(symbol: "gearshape", label: "Settings", size: .header, isFocused: focus == .settings) {
                openSettingsWindow()
            }
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
                .focused($filterFocused)
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

    /// What the list shows right now, in display order. Rendering and keyboard navigation share it.
    private struct Content {
        var running: [ProjectRow]
        var needsApproval: [ProjectRow]
        var stopped: [ProjectRow]
        var other: [ListenerGroup]
        /// Rows hidden behind "Show N more".
        var hiddenOtherCount: Int

        var order: [MenuRowID] {
            (running + needsApproval + stopped).map { .project($0.id) } + other.map { .listener($0.id) }
        }
    }

    private var showsFilter: Bool { totalRowCount >= 6 }

    /// Each visible row with its action buttons, in display order.
    private func focusRows(_ shown: Content) -> [MenuNavigation.FocusRow] {
        (shown.running + shown.needsApproval + shown.stopped).map {
            .init(id: .project($0.id), actions: ProjectActions.rowActions(for: $0, registry: registry))
        } + shown.other.map {
            .init(id: .listener($0.id), actions: ListenerActions.rowActions(for: $0))
        }
    }

    /// Every focusable control in Tab order (DESIGN.md §5).
    private var focusOrder: [MenuFocus] {
        let shown = content
        return MenuNavigation.focusOrder(
            rows: isEmpty ? [] : focusRows(shown),
            showsFilter: showsFilter,
            showsShowMore: !isEmpty && shown.hiddenOtherCount > 0,
            canStopAll: registry.hasManagedServers
        )
    }

    private var content: Content {
        let other = registry.visibleOtherListeners.filter { matchesListener($0) }
        // While filtering, show every match; otherwise collapse to the first few.
        let collapsed = filter.isEmpty && !showAllOther && other.count > Self.otherListenerLimit
        let shownOther = collapsed ? Array(other.prefix(Self.otherListenerLimit)) : other
        return Content(
            running: registry.runningRows.filter { matchesRow($0) },
            needsApproval: registry.needsApprovalRows.filter { matchesRow($0) },
            stopped: registry.stoppedRows.filter { matchesRow($0) },
            other: shownOther,
            hiddenOtherCount: other.count - shownOther.count
        )
    }

    @ViewBuilder
    private var sections: some View {
        let shown = content
        let groups: [(String, AnyView)] = [
            ("Running", AnyView(projectRows(shown.running))),
            ("Needs approval", AnyView(projectRows(shown.needsApproval))),
            ("Stopped", AnyView(projectRows(shown.stopped))),
            ("Other listeners", AnyView(VStack(spacing: 0) {
                ForEach(shown.other) { group in
                    OtherListenerRow(
                        group: group,
                        isSelected: focus?.rowID == .listener(group.id),
                        focusedAction: focusedAction(in: .listener(group.id))
                    )
                    .id(MenuRowID.listener(group.id))
                }
                if shown.hiddenOtherCount > 0 {
                    ShowMoreRow(count: shown.hiddenOtherCount, isFocused: focus == .showMore) { showMore() }
                        .id(MenuFocus.showMore)
                }
            })),
        ]
        let counts = [shown.running.count, shown.needsApproval.count, shown.stopped.count, shown.other.count]
        let visible = groups.indices.filter { counts[$0] > 0 }

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

    private func projectRows(_ rows: [ProjectRow]) -> some View {
        ForEach(rows) { row in
            ServerRow(
                row: row,
                isSelected: focus?.rowID == .project(row.id),
                focusedAction: focusedAction(in: .project(row.id))
            )
            .id(MenuRowID.project(row.id))
        }
    }

    private func focusedAction(in row: MenuRowID) -> RowAction? {
        if case .action(row, let action) = focus { return action }
        return nil
    }

    /// Reveals the collapsed listeners and moves focus to the first one it revealed.
    private func showMore() {
        let other = registry.visibleOtherListeners.filter { matchesListener($0) }
        showAllOther = true
        if focus == .showMore {
            focus = other.indices.contains(Self.otherListenerLimit)
                ? .row(.listener(other[Self.otherListenerLimit].id)) : nil
        }
    }

    // MARK: - Keyboard (DESIGN.md §5)

    private var actions: ProjectActions { ProjectActions(registry: registry, openWindow: openWindow) }

    /// Returns true when the key was handled (and should not reach the filter field / window).
    private func handleKey(_ press: KeyPress) -> Bool {
        guard let command = MenuNavigation.command(
            keyCode: press.keyCode,
            characters: press.characters,
            modifiers: press.modifiers,
            filterIsEmpty: filter.isEmpty,
            filterFocused: filterFocused
        ) else { return false }

        let shown = content
        let rows = isEmpty ? [] : focusRows(shown)
        let order = focusOrder
        if let current = focus, !order.contains(current) { focus = nil }
        let rowID = focus?.rowID
        let selectedProject = rowID.flatMap { id -> ProjectRow? in
            guard case .project(let projectID) = id else { return nil }
            return registry.projects.first { $0.id == projectID }
        }
        let selectedListener = rowID.flatMap { id -> ListenerGroup? in
            guard case .listener(let groupID) = id else { return nil }
            return registry.otherListeners.first { $0.id == groupID }
        }

        switch command {
        case .moveUp, .moveDown:
            let next = MenuNavigation.move(rowID, in: rows.map(\.id), by: command == .moveUp ? -1 : 1)
            focus = next.map { MenuFocus.row($0) } ?? focus
        case .moveLeft, .moveRight:
            guard let focused = focus, let rowID, let row = rows.first(where: { $0.id == rowID }) else {
                return false
            }
            focus = MenuNavigation.step(focused, actions: row.actions, by: command == .moveLeft ? -1 : 1)
        case .nextFocus, .previousFocus:
            focus = MenuNavigation.advance(focus, in: order, by: command == .nextFocus ? 1 : -1)
            filterFocused = focus == .filter
        case .activate:
            let target = focus
            if MenuNavigation.activationLeavesMenu(target, projectState: selectedProject?.state) {
                MenuBarToggle.closeIfOpen()
            }
            activate(target, project: selectedProject, listener: selectedListener)
        case .stop:
            guard let selectedProject else { return false }
            actions.stop(selectedProject)
        case .restart:
            guard let selectedProject else { return false }
            actions.restart(selectedProject)
        case .logs:
            guard let selectedProject else { return false }
            MenuBarToggle.closeIfOpen()
            actions.showLogs(selectedProject)
        case .copyURL:
            if let port = selectedProject?.project.port ?? selectedListener?.port {
                URLActions.copy(port: port)
            } else {
                return false
            }
        case .settings:
            MenuBarToggle.closeIfOpen()
            openSettingsWindow()
        case .clearFilter:
            filter = ""
        case .type(let text):
            // The filter field only exists with 6+ rows (DESIGN.md §4.1).
            guard showsFilter else { return false }
            filterFocused = true
            filter += text
        }
        // Return and Space with nothing focused are swallowed too, so Space never lands in the filter.
        return true
    }

    /// Return / Space: press whatever has keyboard focus, exactly as a click would.
    private func activate(_ focus: MenuFocus?, project: ProjectRow?, listener: ListenerGroup?) {
        switch focus {
        case nil, .filter:
            break
        case .addServer, .footerAdd:
            addServer()
        case .settings:
            openSettingsWindow()
        case .row:
            if let project {
                actions.primary(project)
            } else if let listener {
                URLActions.open(port: listener.port)
            }
        case .action(_, let action):
            if let project {
                actions.perform(action, on: project)
            } else if let listener {
                ListenerActions(addServerModel: addServerModel, openWindow: openWindow).perform(action, on: listener)
            }
        case .showMore:
            showMore()
        case .footerStopAll:
            if registry.hasManagedServers {
                Task { await registry.stopAllManaged() }
            }
        }
    }

    private func openSettingsWindow() {
        NSApp.activate()
        openSettings()
        WindowFront.raise(WindowID.settings)
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
            FooterRow(title: "Add Server from Folder…", shortcut: "⌘N", isFocused: focus == .footerAdd) { addServer() }
                .keyboardShortcut("n", modifiers: .command)
            FooterRow(title: "Stop All Managed Servers", isFocused: focus == .footerStopAll) {
                Task { await registry.stopAllManaged() }
            }
            .disabled(!registry.hasManagedServers)
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
        WindowFront.raise(WindowID.addServer)
    }
}

private struct ShowMoreRow: View {
    let count: Int
    var isFocused = false
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
            .menuFocusRing(isFocused, cornerRadius: 6)
            .accessibilityAddTraits(isFocused ? .isSelected : [])
    }
}

private struct FooterRow: View {
    let title: String
    var shortcut: String?
    var isFocused = false
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
                (isHovering || isFocused) && isEnabled ? Tokens.Colors.fillControl : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .menuFocusRing(isFocused, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .onHover { isHovering = $0 }
    }
}
