import AppKit
import Models
import Registry
import Supervisor
import SwiftUI

/// Per-project log window (AGENTS.md §9.4, DESIGN.md §4.4): monospace, ANSI colours, search,
/// Copy All (Redacted), Clear, Reveal Log File, follow the newest output.
///
/// Secrets are redacted on display and on copy (§6.3); the file on disk keeps raw output (mode 0600).
struct LogWindow: View {
    let projectID: UUID?
    @Environment(ServerRegistry.self) private var registry
    @State private var store: LogStore?
    @State private var lines: [LogBuffer.Line] = []
    @State private var version = -1
    @State private var search = ""
    @State private var follow = true

    private var row: ProjectRow? {
        registry.projects.first { $0.id == projectID }
    }

    private var startedInTerminal: Bool {
        guard let row, case .running(let managed, _, _) = row.state else { return false }
        return !managed
    }

    private var visibleLines: [LogBuffer.Line] {
        guard !search.isEmpty else { return lines }
        return lines.filter { $0.plain.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if startedInTerminal {
                Text("This server was started in Terminal, so its output is there. Restart it in Runner to see logs here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                Text(store == nil ? "No output yet." : "Waiting for output…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                output
            }
        }
        .navigationTitle("\(row?.project.name ?? "Server") — Logs")
        .searchable(text: $search, placement: .toolbar, prompt: "Search output")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $follow) {
                    Label("Follow", systemImage: "arrow.down.to.line")
                }
                .help("Keep scrolled to the newest output")
                Button("Copy All (Redacted)") { copyAll() }
                    .disabled(lines.isEmpty)
                Button("Clear") { store?.clear() }
                    .disabled(lines.isEmpty)
                Button("Reveal Log File") { revealFile() }
                    .disabled(store?.fileURL == nil)
            }
        }
        .frame(minWidth: 480, minHeight: 280)
        .task(id: projectID) { await stream() }
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                        Text(ANSIText.attributed(Redactor.redact(line.raw)))
                            .font(.system(size: 12, design: .monospaced))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(12)
                .textSelection(.enabled)
            }
            .onChange(of: version) {
                if follow { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    private static let bottomID = "bottom"

    /// Polls the log store a few times a second; only re-renders when its version changes.
    private func stream() async {
        guard let projectID else { return }
        while !Task.isCancelled {
            // A restart replaces the store; follow it.
            let latest = await registry.logStore(for: projectID)
            if latest !== store {
                store = latest
                version = -1
            }
            if let store {
                let snapshot = store.snapshot()
                if snapshot.version != version {
                    lines = snapshot.lines
                    version = snapshot.version
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func copyAll() {
        let text = lines.map { Redactor.redact($0.plain) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func revealFile() {
        guard let url = store?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
