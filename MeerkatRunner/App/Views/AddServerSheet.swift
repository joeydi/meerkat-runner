import AppKit
import Detection
import Models
import Registry
import SwiftUI

/// Add server from folder (AGENTS.md §9.2, DESIGN.md §4.2). Presented in its own 540 pt window.
///
/// Picking a folder runs the detectors (which never execute anything) and shows the proposals.
/// Add / Add and Start save through the registry, which approves exactly the command shown here.
struct AddServerSheet: View {
    @Environment(AddServerModel.self) private var model
    @Environment(ServerRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            header

            if model.workspaceServers.count >= 2, !model.isDetecting {
                Toggle(isOn: $model.addsEachWorkspace) {
                    Text("Add each app as its own server (\(model.workspaceServers.count) in this monorepo)")
                }
                .toggleStyle(.checkbox)
            }

            if model.addsEachWorkspace {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Which apps?").font(Tokens.Font.label)
                    workspaceCard
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How should it start?").font(Tokens.Font.label)
                    commandCard
                }
                singleServerFields
            }

            VStack(alignment: .leading, spacing: 6) {
                if !model.addsEachWorkspace {
                    ForEach($model.envFiles) { $file in
                        Toggle(isOn: $file.isOn) {
                            Text("Load \(file.name) (\(variableText(file.variableCount)), values hidden)")
                        }
                    }
                }
                Toggle("Start when I log in", isOn: $model.startAtLogin)
                Toggle(isOn: $model.bindToLocalhost) {
                    Text("Bind to localhost only")
                }
                .disabled(!model.addsEachWorkspace && !model.canBindToLocalhost)
                .help("Adds the framework's host flag (or HOST=127.0.0.1) so other devices on your network can't reach it.")
                if !model.addsEachWorkspace, !model.canBindToLocalhost {
                    Text("Docker publishes this project's ports; set the bind address in the compose file.")
                        .font(Tokens.Font.meta)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
            .toggleStyle(.checkbox)

            InfoCallout(text: callout)

            if let errorMessage {
                Text(errorMessage)
                    .font(Tokens.Font.meta)
                    .foregroundStyle(Tokens.Colors.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button(addTitle) { save(start: false) }
                    .disabled(!model.canAdd || isSaving)
                Button(addAndStartTitle) { save(start: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdd || isSaving)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 540)
        .modifier(FolderDrop(isTargeted: $isDropTargeted) { model.load($0) })
        .onAppear(perform: showPickerIfRequested)
        .onChange(of: model.wantsFolderPicker) { showPickerIfRequested() }
    }

    private var addTitle: String {
        model.addsEachWorkspace ? "Add \(selectedWorkspaceCount)" : "Add"
    }

    private var addAndStartTitle: String {
        model.addsEachWorkspace ? "Add and Start \(selectedWorkspaceCount)" : "Add and Start"
    }

    private var selectedWorkspaceCount: Int { model.workspaceServers.filter(\.isOn).count }

    // MARK: - Single server: name, port, health URL

    private var singleServerFields: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Name").font(Tokens.Font.label)
                    Text("Port").font(Tokens.Font.label)
                }
                GridRow {
                    TextField("Name", text: $model.name)
                        .textFieldStyle(.roundedBorder)
                    TextField(model.predictedPort.map(String.init) ?? "Auto", text: $model.portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                GridRow {
                    Color.clear.frame(height: 0)
                    Text(portHint.text)
                        .font(Tokens.Font.meta)
                        .foregroundStyle(portHint.isWarning ? Tokens.Colors.warningText : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 180, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Health check URL (optional)").font(Tokens.Font.label)
                TextField(healthPlaceholder, text: $model.healthURLText)
                    .textFieldStyle(.roundedBorder)
                    .font(Tokens.Font.code)
                Text(model.healthURLError ?? "Runner shows it as running once this answers, not just when the port opens.")
                    .font(Tokens.Font.meta)
                    .foregroundStyle(model.healthURLError == nil ? Color.secondary : Tokens.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var healthPlaceholder: String {
        "http://localhost:\(model.effectivePort.map(String.init) ?? "3000")/"
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 20))
                .frame(width: 40, height: 40)
                .background(Tokens.Colors.fillControl, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.folder.map { "Add \($0.lastPathComponent)" } ?? "Add Server").font(Tokens.Font.title)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle)
                        .font(Tokens.Font.bodySmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button(model.folder == nil ? "Choose Folder…" : "Change Folder…") { chooseFolder() }
                .buttonStyle(.link)
        }
    }

    // MARK: - Commands

    @ViewBuilder
    private var commandCard: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            if model.folder == nil {
                cardMessage("Choose a folder, or drag one here from Finder, to see how it starts.")
            } else if model.isDetecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading project files…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
            } else {
                if model.proposals.isEmpty {
                    cardMessage("Couldn't find a start command in this folder.")
                    Divider()
                }
                ForEach(Array(model.proposals.enumerated()), id: \.offset) { index, proposal in
                    let isSelected = model.selection == index
                    CommandOption(
                        proposal: proposal,
                        // The selected command is shown exactly as it will be approved and run.
                        command: isSelected ? model.displayedCommand ?? proposal.command : proposal.command,
                        environmentText: isSelected ? model.bindEnvironmentText : nil,
                        isSuggested: index == 0,
                        isSelected: isSelected
                    ) { model.selection = index }
                    Divider()
                }
                customOption
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var customOption: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            Button { model.selection = nil } label: {
                HStack(spacing: 10) {
                    RadioDot(isSelected: model.isCustom)
                    Text("Custom command…").font(.body)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.isCustom ? .isSelected : [])

            if model.isCustom {
                TextField("e.g. npm run dev -- --port 4000", text: $model.customCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(Tokens.Font.code)
                Toggle("Run as shell command", isOn: $model.customIsShell)
                    .toggleStyle(.checkbox)
                if model.customIsShell {
                    Text("Shell commands can run anything your shell can. Only use this if you trust every part of the command.")
                        .font(Tokens.Font.meta)
                        .foregroundStyle(Tokens.Colors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let error = model.customCommandError {
                    Text(error)
                        .font(Tokens.Font.meta)
                        .foregroundStyle(Tokens.Colors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let environment = model.bindEnvironmentText {
                    Text("Runs with \(environment)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    // MARK: - Workspaces ("Add each as its own server")

    private var workspaceCard: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            ForEach($model.workspaceServers) { $server in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $server.isOn) {
                        HStack(spacing: 8) {
                            Text(server.name).font(.body.weight(.medium))
                            Text(server.relativePath).font(Tokens.Font.meta).foregroundStyle(.secondary)
                            if let framework = server.proposal.framework {
                                Text("· \(framework)").font(Tokens.Font.meta).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    // Exactly what each server runs, in its own folder (§8.2: nothing runs unseen).
                    Text(model.workspaceCommand(for: server))
                        .font(.system(size: 12.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.leading, 20)
                    if let script = server.proposal.resolvedScript {
                        Text("runs: \(script)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(Tokens.Colors.fillCode, in: RoundedRectangle(cornerRadius: 6))
                            .padding(.leading, 20)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                if server.id != model.workspaceServers.last?.id { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func cardMessage(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Font.bodySmall)
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
    }

    // MARK: - Hints

    private var portHint: (text: String, isWarning: Bool) {
        if let port = model.effectivePort,
           let owner = registry.otherListeners.first(where: { $0.port == port }) {
            // The server being added is usually the one holding the port: not a conflict.
            if let cwd = owner.cwd, let folder = model.folder,
               URL(fileURLWithPath: cwd).standardizedFileURL.path == folder.standardizedFileURL.path {
                return ("Already running here. After adding, Restart in Runner takes it over.", false)
            }
            let place = owner.cwd.map { " (\(Format.abbreviatingHome($0)))" } ?? ""
            return ("In use by \(owner.processName)\(place)", true)
        }
        if model.selectedProposal?.notes.contains(PythonDetector.airPlayNote) == true {
            return (PythonDetector.airPlayNote, true)
        }
        return (model.portHint, false)
    }

    private var callout: Text {
        if model.addsEachWorkspace {
            return Text(
                "Each command runs as you, inside its app's folder. Nothing has run yet. If a script changes later, you'll be asked to approve it again."
            )
        }
        let path = model.folder.map { Format.abbreviatingHome($0.path) } ?? "the project folder"
        let code = Text(path).font(.system(size: 12, design: .monospaced))
        return Text(
            "This command runs as you, inside \(code). Nothing has run yet. If the script changes later, you'll be asked to approve it again."
        )
    }

    private func variableText(_ count: Int?) -> String {
        guard let count else { return "unreadable" }
        return count == 1 ? "1 variable" : "\(count) variables"
    }

    // MARK: - Actions

    private func chooseFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a project folder. Runner reads its files to find how it starts; nothing runs."
        if let folder = model.folder { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url {
            model.load(url)
        }
    }

    private func showPickerIfRequested() {
        guard model.wantsFolderPicker else { return }
        model.wantsFolderPicker = false
        // Let the window finish appearing before running the modal panel.
        DispatchQueue.main.async { chooseFolder() }
    }

    private func save(start: Bool) {
        let toAdd = model.addsEachWorkspace ? model.makeWorkspaceProjects() : model.makeProject().map { [$0] } ?? []
        guard !toAdd.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            var added: [Project] = []
            do {
                for made in toAdd {
                    try await registry.add(made.project, shownScript: made.shownScript)
                    added.append(made.project)
                }
                close()
                if start {
                    for project in added { await startAdded(project) }
                }
            } catch ServerRegistry.ProjectError.changedWhileReviewing {
                let saved = added.isEmpty ? "" : " \(added.count) of \(toAdd.count) were added."
                errorMessage = "The project's files changed while this window was open. Review the command again.\(saved)"
                if let folder = model.folder { model.load(folder) }
            } catch {
                errorMessage = "Couldn't save the project."
            }
        }
    }

    private func startAdded(_ project: Project) async {
        do {
            try await registry.startProject(project.id)
        } catch ServerRegistry.StartError.failed(let message) {
            Alerts.show("Couldn't start \(project.name)", message)
        } catch {}
    }

    private func close() {
        model.reset()
        dismiss()
    }
}

/// Drag a project folder from Finder onto the Add window. (The menu itself can't take drops: a
/// MenuBarExtra window closes as soon as Finder becomes active.)
private struct FolderDrop: ViewModifier {
    @Binding var isTargeted: Bool
    let load: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                let folder = urls.first { url in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                }
                guard let folder else { return false }
                load(folder)
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// One proposal in the command card (DESIGN.md §3 `CommandOption`).
private struct CommandOption: View {
    let proposal: Proposal
    /// What's shown: the proposal's command, plus localhost-bind arguments when selected.
    let command: LaunchCommand
    /// e.g. `HOST=127.0.0.1` when the bind uses env.
    var environmentText: String?
    let isSuggested: Bool
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    RadioDot(isSelected: isSelected)
                    // The selected command is shown in full: nothing runs that the user hasn't seen (§8).
                    Text(command.displayString)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular, design: .monospaced))
                        .lineLimit(isSelected ? nil : 1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: isSelected)
                    if isSuggested {
                        Badge(text: "Suggested", style: .accent)
                    }
                    if command.isShell {
                        Badge(text: "Shell command", style: .warning)
                    }
                    Spacer(minLength: 8)
                    Text(sourceLine)
                        .font(Tokens.Font.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isSelected, let environmentText {
                    Text("Runs with \(environmentText)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 22)
                }
                if isSelected, let script = proposal.resolvedScript, script != proposal.command.displayString {
                    Text("runs: \(script)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Tokens.Colors.fillCode, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.leading, 22)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// `package.json · needs a build first`
    private var sourceLine: String {
        ([proposal.source] + proposal.notes.filter { $0 != PythonDetector.airPlayNote }).joined(separator: " · ")
    }
}

private struct RadioDot: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1.5)
            if isSelected {
                Circle().fill(Color.accentColor).padding(4)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}
