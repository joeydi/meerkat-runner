import Models
import Registry
import SwiftUI

/// "The start script for <name> changed" (AGENTS.md §9.3, DESIGN.md §4.3). Own 460 pt window.
///
/// Keyboard: Esc = Don't Run. Return is deliberately **not** bound to Approve — approval must be a
/// click (open question §13 Q2). Focus starts on Don't Run.
///
/// TODO(v0.2): load old/new `displayedCommand` + `resolvedScript`, compute the line diff, list
/// referenced files with Reveal in Finder, wire Approve and Start through the approval gate, and show
/// "Run previous version" only when the previous argv command can be reconstructed exactly.
struct ReapprovalSheet: View {
    let projectID: UUID?
    @Environment(ServerRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss

    private var row: ProjectRow? {
        registry.projects.first { $0.id == projectID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Tokens.Colors.warningText)
                    .frame(width: 40, height: 40)
                    .background(Tokens.Colors.warningFill, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text("The start script for \(row?.project.name ?? "this server") changed")
                        .font(Tokens.Font.title)
                    Text(subtitle)
                        .font(Tokens.Font.bodySmall)
                        .foregroundStyle(.secondary)
                }
            }

            DiffView(
                title: "scripts.dev",
                lines: [
                    .removed(row?.project.approval?.resolvedScript ?? row?.project.approval?.displayedCommand ?? ""),
                    .added("…"),
                ]
            )

            Divider()

            HStack {
                // "Run previous version" goes here (leading, link style) when reconstructable.
                Spacer()
                Button("Don't Run") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Approve and Start") {
                    // TODO(v0.2): approve via ApprovalGate, then start.
                }
                .buttonStyle(.borderedProminent)
                // No .keyboardShortcut: approving always takes a click.
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 460)
    }

    private var subtitle: String {
        guard let approvedAt = row?.project.approval?.approvedAt else {
            return "Review the new command before it runs."
        }
        let sameYear = Calendar.current.isDate(approvedAt, equalTo: .now, toGranularity: .year)
        let date = approvedAt.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
        return "It was edited since you approved it on \(date). Review the new command before it runs."
    }
}
