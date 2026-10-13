import AppKit
import Detection
import Models
import Registry
import SwiftUI

/// Add server from folder (AGENTS.md §9.2, DESIGN.md §4.2). Presented in its own 540 pt window.
///
/// Read-only for now: picking a folder runs the detectors (which never execute anything) and shows
/// the proposals. TODO(v0.2, next step): Add / Add and Start save through the approval gate.
struct AddServerSheet: View {
    @Environment(AddServerModel.self) private var model
    @Environment(ServerRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(alignment: .leading, spacing: 8) {
                Text("How should it start?").font(Tokens.Font.label)
                commandCard
            }

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

            VStack(alignment: .leading, spacing: 6) {
                ForEach($model.envFiles) { $file in
                    Toggle(isOn: $file.isOn) {
                        Text("Load \(file.name) (\(variableText(file.variableCount)), values hidden)")
                    }
                }
                Toggle("Start when I log in", isOn: $model.startAtLogin)
                // "Bind to localhost only" arrives with the framework flags in v0.3 (§6.6).
            }
            .toggleStyle(.checkbox)

            InfoCallout(text: callout)

            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {}
                    .disabled(true)
                Button("Add and Start") {}
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(true)
            }
            .controlSize(.large)
            .help("Saving and starting arrive in the next v0.2 step.")
        }
        .padding(24)
        .frame(width: 540)
        // Drag a project folder from Finder onto this window. (The menu itself can't take drops:
        // a MenuBarExtra window closes as soon as Finder becomes active.)
        .dropDestination(for: URL.self) { urls, _ in
            let folder = urls.first { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            guard let folder else { return false }
            model.load(folder)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onAppear(perform: showPickerIfRequested)
        .onChange(of: model.wantsFolderPicker) { showPickerIfRequested() }
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
                    CommandOption(
                        proposal: proposal,
                        isSuggested: index == 0,
                        isSelected: model.selection == index
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
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
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

    private func close() {
        model.reset()
        dismiss()
    }
}

/// One proposal in the command card (DESIGN.md §3 `CommandOption`).
private struct CommandOption: View {
    let proposal: Proposal
    let isSuggested: Bool
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    RadioDot(isSelected: isSelected)
                    // The selected command is shown in full: nothing runs that the user hasn't seen (§8).
                    Text(proposal.command.displayString)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular, design: .monospaced))
                        .lineLimit(isSelected ? nil : 1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: isSelected)
                    if isSuggested {
                        Badge(text: "Suggested", style: .accent)
                    }
                    if proposal.command.isShell {
                        Badge(text: "Shell command", style: .warning)
                    }
                    Spacer(minLength: 8)
                    Text(sourceLine)
                        .font(Tokens.Font.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
