import Models
import Registry
import SwiftUI

/// Per-project log window (AGENTS.md §9.4, DESIGN.md §4.4).
///
/// TODO(v0.2): stream `LogBuffer` lines with ANSI colours, search over the stripped copy,
/// "Copy All (Redacted)" via `Redactor`, Clear, Reveal Log File, auto-scroll unless scrolled up
/// with a "Jump to latest" pill. Terminal-started servers show the "Output is in your terminal" state.
struct LogWindow: View {
    let projectID: UUID?
    @Environment(ServerRegistry.self) private var registry
    @State private var search = ""

    private var row: ProjectRow? {
        registry.projects.first { $0.id == projectID }
    }

    var body: some View {
        Group {
            if let row, row.state.isRunning, !row.state.isManaged {
                Text("This server was started in Terminal, so its output is there. Restart it in Runner to see logs here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text("No output yet.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("\(row?.project.name ?? "Server") — Logs")
        .searchable(text: $search)
        .toolbar {
            Button("Copy All (Redacted)") {}.disabled(true)
            Button("Clear") {}.disabled(true)
            Button("Reveal Log File") {}.disabled(true)
        }
        .frame(minWidth: 480, minHeight: 280)
    }
}
