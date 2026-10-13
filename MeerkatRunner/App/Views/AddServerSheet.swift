import AppKit
import Models
import Registry
import SwiftUI

/// Add server from folder (AGENTS.md §9.2, DESIGN.md §4.2). Presented in its own 540 pt window.
///
/// TODO(v0.2): run `DetectionEngine`, show `CommandOption`s, Custom command (argv editor + shell toggle),
/// Name/Port fields, env-file checkboxes (variable counts, never values), Start at login, Bind to localhost,
/// then hand the chosen proposal to the approval gate.
struct AddServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Text("How should it start?").font(Tokens.Font.label)
            Text(folder == nil ? "Choose a folder to detect its start command." : "Detection arrives in v0.2.")
                .font(Tokens.Font.bodySmall)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))

            LabeledContent("Name") {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            }
            .font(Tokens.Font.label)

            InfoCallout(text: Text(callout))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {}
                    .disabled(true)
                Button("Add and Start") {}
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(true)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 540)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 20))
                .frame(width: 40, height: 40)
                .background(Tokens.Colors.fillControl, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.map { "Add \($0.lastPathComponent)" } ?? "Add Server").font(Tokens.Font.title)
                if let folder {
                    Text(Format.abbreviatingHome(folder.path))
                        .font(Tokens.Font.bodySmall)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(folder == nil ? "Choose Folder…" : "Change Folder…") { chooseFolder() }
                .buttonStyle(.link)
        }
    }

    private var callout: String {
        let path = folder.map { Format.abbreviatingHome($0.path) } ?? "the project folder"
        return "This command runs as you, inside \(path). Nothing has run yet. "
            + "If the script changes later, you'll be asked to approve it again."
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            if name.isEmpty { name = url.lastPathComponent }
        }
    }
}
