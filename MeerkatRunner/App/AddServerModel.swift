import Detection
import Foundation
import Models
import Observation

/// State for the Add server window (AGENTS.md §5 flow, §9.2). Shared so the menu's "+", folder drops
/// and "Add as server…" on an Other listeners row can all pre-fill it.
///
/// Detection only reads files; nothing here runs anything. Saving and starting go through the
/// approval gate (next v0.2 step).
@MainActor
@Observable
final class AddServerModel {
    struct EnvFileOption: Identifiable, Equatable {
        var name: String
        /// Number of variables declared. Values are never read into the UI.
        var variableCount: Int?
        /// `PORT` declared in the file, used only for port prediction.
        var port: Int?
        var isOn: Bool

        var id: String { name }
    }

    private(set) var folder: URL?
    private(set) var proposals: [Proposal] = []
    private(set) var isDetecting = false
    private(set) var packageManager: NodeDetector.PackageManager?

    /// Index into `proposals`; nil selects the custom command.
    var selection: Int?
    var customCommand = ""
    var customIsShell = false
    var name = ""
    /// User-entered port; empty means "use the prediction".
    var portText = ""
    var envFiles: [EnvFileOption] = []
    var startAtLogin = false
    /// Set by "Add Server from Folder…" so the window shows the folder picker even if already open.
    var wantsFolderPicker = false

    @ObservationIgnored private var loadID = UUID()

    // MARK: - Loading

    /// Clears the window and asks it to show the folder picker.
    func requestFolderPicker() {
        reset()
        wantsFolderPicker = true
    }

    func reset() {
        loadID = UUID()
        folder = nil
        proposals = []
        isDetecting = false
        packageManager = nil
        selection = nil
        customCommand = ""
        customIsShell = false
        name = ""
        portText = ""
        envFiles = []
        startAtLogin = false
    }

    /// A server already running in the folder, offered as a proposal ("Add as server…").
    struct RunningServer: Sendable {
        var argv: [String]
        var port: Int
        var framework: String?
    }

    /// Detects start commands for `url`. Safe to call repeatedly; only the latest call wins.
    /// With `running`, also proposes that process's own command line.
    func load(_ url: URL, running: RunningServer? = nil) {
        reset()
        let folder = url.standardizedFileURL.resolvingSymlinksInPath()
        self.folder = folder
        name = folder.lastPathComponent
        isDetecting = true
        let id = loadID

        Task {
            let result = await Self.detect(folder)
            guard id == loadID else { return }
            proposals = result.proposals
            if let running,
               let proposal = RunningProcessProposal.make(
                   argv: running.argv, folder: folder, port: running.port,
                   framework: running.framework, rankedFirst: proposals.isEmpty
               ),
               !proposals.contains(where: { $0.command == proposal.command }) {
                proposals.append(proposal)
            }
            packageManager = result.packageManager
            envFiles = result.envFiles.enumerated().map { index, file in
                // Pre-select the most specific env file only.
                EnvFileOption(name: file.name, variableCount: file.variableCount, port: file.port, isOn: index == 0)
            }
            selection = proposals.isEmpty ? nil : 0
            isDetecting = false
        }
    }

    struct DetectionResult: Sendable {
        struct EnvFileInfo: Sendable {
            var name: String
            var variableCount: Int?
            var port: Int?
        }

        var proposals: [Proposal]
        var packageManager: NodeDetector.PackageManager?
        var envFiles: [EnvFileInfo]
    }

    /// Runs off the main actor: file reads only.
    nonisolated static func detect(_ folder: URL) async -> DetectionResult {
        let proposals = await DetectionEngine.detect(in: folder)
        let snapshot = FileSnapshot.read(folder)
        let manager = snapshot.exists("package.json")
            ? NodeDetector.packageManager(files: snapshot, packageJSON: snapshot.json("package.json"))
            : nil
        let envFiles = EnvFile.candidates(topLevel: snapshot.topLevel).map { name in
            let url = folder.appendingPathComponent(name)
            let text = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
            return DetectionResult.EnvFileInfo(
                name: name,
                variableCount: EnvFile.keyCount(at: url),
                port: text.flatMap(PortPrediction.envPort(in:))
            )
        }
        return DetectionResult(proposals: proposals, packageManager: manager, envFiles: envFiles)
    }

    // MARK: - Saving

    var canAdd: Bool {
        folder != nil && !isDetecting && launchCommand != nil
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The project to save, without an approval: the registry approves exactly `shownScript`.
    func makeProject() -> (project: Project, shownScript: String?)? {
        guard let folder, let command = launchCommand else { return nil }
        let project = Project(
            name: name.trimmingCharacters(in: .whitespaces),
            path: folder.path,
            bookmark: try? folder.bookmarkData(),
            detector: selectedProposal?.detector ?? .custom,
            command: command,
            envFiles: envFiles.filter(\.isOn).map(\.name),
            expectedPort: effectivePort,
            autoStartAtLogin: startAtLogin
        )
        return (project, selectedProposal?.resolvedScript)
    }

    // MARK: - Derived

    var selectedProposal: Proposal? {
        selection.flatMap { proposals.indices.contains($0) ? proposals[$0] : nil }
    }

    var isCustom: Bool { selection == nil }

    /// argv for the custom command, or nil if it needs a shell.
    var customArgv: [String]? { ShellWords.split(customCommand) }

    var customCommandError: String? {
        guard isCustom, !customIsShell, !customCommand.trimmingCharacters(in: .whitespaces).isEmpty,
              customArgv == nil
        else { return nil }
        return "This needs a shell (it has a pipe, variable, glob or similar). "
            + "Simplify it, or turn on Run as shell command."
    }

    /// What would be saved and approved.
    var launchCommand: LaunchCommand? {
        if let proposal = selectedProposal { return proposal.command }
        let trimmed = customCommand.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return customIsShell ? .shell(trimmed) : customArgv.map(LaunchCommand.argv)
    }

    /// Explicit `--port` in the script, then `PORT` in a selected env file, then the detector's guess.
    var predictedPort: Int? {
        if let script = selectedProposal?.resolvedScript, let port = PortPrediction.explicitPort(in: script) {
            return port
        }
        if let port = envFiles.first(where: { $0.isOn && $0.port != nil })?.port { return port }
        return selectedProposal?.predictedPort
    }

    var effectivePort: Int? { Int(portText) ?? predictedPort }

    var portHint: String {
        if Int(portText) != nil { return "Learned on first run if different" }
        if let script = selectedProposal?.resolvedScript, PortPrediction.explicitPort(in: script) != nil {
            return "From --port in the script"
        }
        if let file = envFiles.first(where: { $0.isOn && $0.port != nil }) {
            return "From PORT in \(file.name)"
        }
        if let proposal = selectedProposal, proposal.predictedPort != nil {
            if proposal.detector == .compose { return "From ports in \(proposal.source)" }
            if let framework = proposal.framework?.split(separator: " ").first {
                return "\(framework) default · learned on first run"
            }
        }
        return "Learned on first run"
    }

    /// `~/Sites/docs · Next.js 15 · pnpm (pnpm-lock.yaml)`
    var subtitle: String {
        guard let folder else { return "" }
        var parts = [(folder.path as NSString).abbreviatingWithTildeInPath]
        if let framework = proposals.first?.framework { parts.append(framework) }
        if let manager = packageManager {
            parts.append(manager.lockfile.map { "\(manager.name) (\($0))" } ?? manager.name)
        }
        return parts.joined(separator: " · ")
    }
}
