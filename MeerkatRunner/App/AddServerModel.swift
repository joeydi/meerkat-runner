import Detection
import Foundation
import Models
import Observation
import Registry

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
    /// "Bind to localhost only" (AGENTS.md §6.6).
    var bindToLocalhost = false
    /// Optional health URL (§6.4); loopback only.
    var healthURLText = ""
    /// One package of a monorepo, offered by "Add each as its own server".
    struct WorkspaceServer: Identifiable, Equatable {
        /// e.g. `apps/web`
        var relativePath: String
        var folder: URL
        var proposal: Proposal
        var isOn = true

        var id: String { relativePath }
        var name: String { folder.lastPathComponent }
    }

    /// Workspace packages with a `dev` script, each detected in its own folder.
    var workspaceServers: [WorkspaceServer] = []
    /// The Add window lists the workspace packages instead of one command.
    var addsEachWorkspace = false
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
        bindToLocalhost = false
        healthURLText = ""
        workspaceServers = []
        addsEachWorkspace = false
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
            workspaceServers = result.workspaces.map {
                WorkspaceServer(relativePath: $0.relativePath, folder: $0.folder, proposal: $0.proposal)
            }
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

        struct Workspace: Sendable {
            var relativePath: String
            var folder: URL
            var proposal: Proposal
        }

        var proposals: [Proposal]
        var packageManager: NodeDetector.PackageManager?
        var envFiles: [EnvFileInfo]
        var workspaces: [Workspace]
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
        return DetectionResult(
            proposals: proposals, packageManager: manager, envFiles: envFiles,
            workspaces: await workspaces(in: folder, snapshot: snapshot)
        )
    }

    /// Each workspace package's own `dev` command, detected in its folder (it runs there, using the
    /// root's package manager), for "Add each as its own server".
    nonisolated static func workspaces(in folder: URL, snapshot: FileSnapshot) async -> [DetectionResult.Workspace] {
        var result: [DetectionResult.Workspace] = []
        for relative in snapshot.workspaces {
            let workspace = folder.appendingPathComponent(relative, isDirectory: true)
            let proposals = await DetectionEngine.detect(in: workspace, detectors: [NodeDetector()])
            if let dev = proposals.first(where: { $0.command.displayString.hasSuffix(" run dev") }) {
                result.append(.init(relativePath: relative, folder: workspace, proposal: dev))
            }
        }
        return result
    }

    // MARK: - Saving

    var canAdd: Bool {
        guard folder != nil, !isDetecting, healthURLError == nil else { return false }
        if addsEachWorkspace { return workspaceServers.contains(where: \.isOn) }
        return launchCommand != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
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
            healthURL: healthURL,
            autoStartAtLogin: startAtLogin,
            preferLocalhostBind: bindToLocalhost && bindOverride != nil,
            localhostBind: bindToLocalhost ? bindOverride : nil
        )
        return (project, selectedProposal?.resolvedScript)
    }

    /// "Add each as its own server": one project per checked workspace package, run in its own folder.
    /// The health URL is per server, so it isn't applied here.
    func makeWorkspaceProjects() -> [(project: Project, shownScript: String?)] {
        workspaceServers.filter(\.isOn).map { server in
            let bind = bindToLocalhost ? LocalhostBinding.override(for: server.proposal, port: server.proposal.predictedPort) : nil
            let project = Project(
                name: server.name,
                path: server.folder.path,
                bookmark: try? server.folder.bookmarkData(),
                detector: server.proposal.detector,
                command: server.proposal.command,
                expectedPort: server.proposal.predictedPort,
                autoStartAtLogin: startAtLogin,
                preferLocalhostBind: bind != nil,
                localhostBind: bind
            )
            return (project, server.proposal.resolvedScript)
        }
    }

    /// The command a workspace package runs, including localhost-bind arguments.
    func workspaceCommand(for server: WorkspaceServer) -> String {
        guard bindToLocalhost, let bind = LocalhostBinding.override(for: server.proposal, port: server.proposal.predictedPort) else {
            return server.proposal.command.displayString
        }
        return server.proposal.command.appending(bind.arguments).displayString
    }

    // MARK: - Localhost bind and health URL

    /// What "Bind to localhost only" adds for the selected command; nil when it can't (Docker Compose).
    var bindOverride: BindOverride? {
        LocalhostBinding.override(for: selectedProposal, port: effectivePort)
    }

    var canBindToLocalhost: Bool { bindOverride != nil }

    /// The exact command that would be approved: the selected one plus any bind arguments.
    var displayedCommand: LaunchCommand? {
        guard let command = launchCommand else { return nil }
        guard bindToLocalhost, let bind = bindOverride else { return command }
        return command.appending(bind.arguments)
    }

    /// e.g. `HOST=127.0.0.1`, shown under the command when the bind uses env.
    var bindEnvironmentText: String? {
        guard bindToLocalhost, let bind = bindOverride, !bind.environment.isEmpty else { return nil }
        return bind.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    var healthURL: URL? { HealthCheck.parse(healthURLText) }

    var healthURLError: String? {
        guard !healthURLText.trimmingCharacters(in: .whitespaces).isEmpty, healthURL == nil else { return nil }
        return "Use an http:// URL on localhost, 127.0.0.1 or [::1]."
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
