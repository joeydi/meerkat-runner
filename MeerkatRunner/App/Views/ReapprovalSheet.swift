import Approval
import Models
import Registry
import SwiftUI

/// "The start script for <name> changed" (AGENTS.md §9.3, DESIGN.md §4.3). Own 460 pt window.
///
/// Shows a line diff of what was approved (command + resolved script) against what the files say now.
/// Approving covers exactly the inputs shown: if the files change again while this is open, the
/// registry refuses and the diff reloads.
///
/// Keyboard: Esc = Don't Run. Return is deliberately **not** bound to Approve: approval must be a
/// click (open question §13 Q2). Focus starts on Don't Run.
///
/// TODO(v0.2 step 3): "Approve and Start", and "Run previous version" when the previous argv command
/// can be reconstructed exactly. Referenced local script files with Reveal in Finder.
struct ReapprovalSheet: View {
    let projectID: UUID?
    @Environment(ServerRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss
    @State private var current: ScriptFingerprint.Input?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var dontRunFocused: Bool

    private var row: ProjectRow? {
        registry.projects.first { $0.id == projectID }
    }

    private var approval: Approval? { row?.project.approval }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if isLoading {
                ProgressView().controlSize(.small)
            } else if let current {
                DiffView(title: "Start command", lines: diffLines(current))
                if sameText(current) {
                    Text("The command and script read the same as before. Something else they depend on changed: the env files, the compose file, or the project's location.")
                        .font(Tokens.Font.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("This project is no longer registered.").foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(Tokens.Font.meta)
                    .foregroundStyle(Tokens.Colors.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Spacer()
                Button("Don't Run") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focused($dontRunFocused)
                Button("Approve") { approve() }
                    .buttonStyle(.borderedProminent)
                    .disabled(current == nil || isSaving)
                // No keyboard shortcut on Approve: approving always takes a click.
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 460)
        .task(id: projectID) { await load() }
        .onAppear { dontRunFocused = true }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Tokens.Colors.warningText)
                .frame(width: 40, height: 40)
                .background(Tokens.Colors.warningFill, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Tokens.Font.title)
                Text(subtitle)
                    .font(Tokens.Font.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        let name = row?.project.name ?? "this server"
        return approval == nil ? "Review the start command for \(name)" : "The start script for \(name) changed"
    }

    private var subtitle: String {
        guard let approvedAt = approval?.approvedAt else {
            return "Its approval was cleared (Runner's saved projects failed an integrity check). Review the command before it runs."
        }
        let sameYear = Calendar.current.isDate(approvedAt, equalTo: .now, toGranularity: .year)
        let date = approvedAt.formatted(
            sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year()
        )
        return "Its files were edited since you approved it on \(date). Review the new command before it runs."
    }

    private func oldLines() -> [String] {
        approval.map { LineDiff.approvalLines(command: $0.displayedCommand, resolvedScript: $0.resolvedScript) } ?? []
    }

    private func newLines(_ input: ScriptFingerprint.Input) -> [String] {
        LineDiff.approvalLines(command: input.command.displayString, resolvedScript: input.resolvedScript)
    }

    private func sameText(_ input: ScriptFingerprint.Input) -> Bool {
        approval != nil && oldLines() == newLines(input)
    }

    private func diffLines(_ input: ScriptFingerprint.Input) -> [DiffView.Line] {
        LineDiff.diff(old: oldLines(), new: newLines(input)).map { line in
            switch line {
            case .same(let text): .context(text)
            case .removed(let text): .removed(text)
            case .added(let text): .added(text)
            }
        }
    }

    private func load() async {
        guard let projectID else {
            isLoading = false
            return
        }
        isLoading = true
        current = await registry.reviewInput(projectID: projectID)
        isLoading = false
    }

    private func approve() {
        guard let projectID, let shown = current else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await registry.approve(projectID: projectID, shown: shown)
                dismiss()
            } catch ServerRegistry.ProjectError.changedWhileReviewing {
                errorMessage = "The files changed again while this was open. Review the updated diff."
                await load()
            } catch {
                errorMessage = "Couldn't save the approval."
            }
        }
    }
}
