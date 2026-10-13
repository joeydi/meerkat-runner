import Approval
import Detection
import Foundation
import Models
import Observation
import Scanner
import Store
import Supervisor

/// The single observable model the UI renders (AGENTS.md §3). Merges the scanner, the project store
/// and the supervisor; publishes on the main actor.
@MainActor
@Observable
public final class ServerRegistry {
    /// Registered projects: running, stopped, crashed, needs approval.
    public private(set) var projects: [ProjectRow] = []
    /// Unmatched listeners, one group per (process, port). View-only: Runner never stops these.
    public private(set) var otherListeners: [ListenerGroup] = []
    /// Set when the store's MAC failed and approvals were cleared; the UI shows a one-time warning.
    public private(set) var storeIntegrityWarning = false
    /// Settings: hide `SystemListeners` from Other listeners. Persisted.
    public var hideSystemListeners: Bool {
        didSet { defaults.set(hideSystemListeners, forKey: Keys.hideSystemListeners) }
    }

    /// Settings: hide listeners owned by desktop apps (`AppListeners`). Persisted.
    public var hideAppListeners: Bool {
        didSet { defaults.set(hideAppListeners, forKey: Keys.hideAppListeners) }
    }

    /// Servers Runner launched (or re-adopted), by project.
    public private(set) var managed: [UUID: ProcessSupervisor.ManagedInfo] = [:]

    /// Called when a server exits without being asked to (§6.8), for the crash notification.
    @ObservationIgnored public var onCrash: (@MainActor (_ project: Project, _ exitCode: Int32) -> Void)?

    private let scanner: PortScanner
    private let store: ProjectStore
    private let supervisor: ProcessSupervisor
    private let shellEnv: ShellEnv
    private let gate: ApprovalGate
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var lastListeners: [Listener] = []
    @ObservationIgnored private let defaults: UserDefaults
    private let logger = RunnerLog.logger(category: "registry")

    enum Keys {
        static let hideSystemListeners = "hideSystemListeners"
        static let hideAppListeners = "hideAppListeners"
    }

    public init(
        scanner: PortScanner = PortScanner(),
        store: ProjectStore = ProjectStore(),
        supervisor: ProcessSupervisor = ProcessSupervisor(),
        shellEnv: ShellEnv = ShellEnv(),
        defaults: UserDefaults = .standard
    ) {
        self.scanner = scanner
        self.store = store
        self.supervisor = supervisor
        self.shellEnv = shellEnv
        gate = ApprovalGate(supervisor: supervisor)
        self.defaults = defaults
        // Both default to on.
        hideSystemListeners = defaults.object(forKey: Keys.hideSystemListeners) as? Bool ?? true
        hideAppListeners = defaults.object(forKey: Keys.hideAppListeners) as? Bool ?? true
    }

    // MARK: - Derived

    public var runningRows: [ProjectRow] {
        projects.filter { $0.state.isRunning || $0.state == .stopping }.sorted { $0.project.name < $1.project.name }
    }

    public var needsApprovalRows: [ProjectRow] {
        projects.filter { $0.state == .needsReapproval }
    }

    public var stoppedRows: [ProjectRow] {
        projects.filter { row in
            switch row.state {
            case .stopped, .crashed, .starting: return true
            case .running, .stopping, .needsReapproval: return false
            }
        }
    }

    /// Other listeners after the "Hide system listeners" / "Hide app listeners" settings, sorted by port.
    public var visibleOtherListeners: [ListenerGroup] {
        otherListeners.filter { group in
            if hideSystemListeners, SystemListeners.isSystemListener(group.primary) { return false }
            if hideAppListeners, AppListeners.isAppListener(group.primary) { return false }
            return true
        }
    }

    /// Menu bar badge: running count (hidden at 0).
    public var runningCount: Int { projects.filter(\.state.isRunning).count }

    /// Whether "Stop All Managed Servers" has anything to do.
    public var hasManagedServers: Bool { !managed.isEmpty }

    // MARK: - Lifecycle

    /// Loads the store, re-adopts servers still running from before a relaunch, and starts polling.
    /// Call once at launch.
    public func start() async {
        logger.info("registry starting")
        await loadStore()
        listenForSupervisorEvents()
        await supervisor.readopt(knownProjects: Set(projects.map(\.id)))
        await refreshManaged()
        setPolling(menuOpen: false)
        await refreshApprovals()
    }

    func loadStore() async {
        do {
            let result = try await store.load()
            projects = result.projects.map { ProjectRow(project: $0, state: .stopped) }
            storeIntegrityWarning = !result.integrityOK
        } catch {
            logger.error("Failed to load project store")
        }
    }

    private func listenForSupervisorEvents() {
        eventsTask?.cancel()
        eventsTask = Task { [weak self, supervisor] in
            for await event in supervisor.events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    func handle(_ event: ProcessSupervisor.Event) {
        switch event {
        case .exited(let projectID, let exitCode, let requested):
            managed[projectID] = nil
            update(projectID) { row in
                if requested || exitCode == nil {
                    row.state = .stopped
                } else if let exitCode {
                    // Any exit Runner didn't ask for counts as a crash (§6.8). No automatic restart.
                    row.state = .crashed(exitCode: exitCode, at: .now)
                }
            }
            if !requested, let exitCode, let project = row(projectID)?.project {
                onCrash?(project, exitCode)
            }
            apply(lastListeners)
        case .portInOutput(let projectID, let port):
            if let row = row(projectID), row.project.learnedPort == nil {
                setLearnedPort(port, for: projectID)
            }
        }
    }

    // MARK: - Projects and approval (AGENTS.md §8.2)

    public enum ProjectError: Error, Sendable, Equatable {
        /// The files changed between showing the command and saving it; nothing was saved.
        case changedWhileReviewing
        case unknownProject
        case storeFailed
    }

    /// Saves a new project, approving exactly what the user was shown.
    ///
    /// - Parameter shownScript: the resolved script displayed in the Add window. If the files now
    ///   resolve to something else, nothing is saved: approval must cover only what was seen.
    public func add(_ project: Project, shownScript: String?) async throws(ProjectError) {
        var project = project
        let current = await inputs(for: project)
        guard current.resolvedScript == shownScript else { throw .changedWhileReviewing }
        project.approval = await gate.approve(current)

        projects.append(ProjectRow(project: project, state: .stopped))
        do {
            try await persist()
        } catch {
            projects.removeAll { $0.id == project.id }
            throw error
        }
        apply(lastListeners)
    }

    public func remove(projectID: UUID) async throws(ProjectError) {
        guard projects.contains(where: { $0.id == projectID }) else { throw .unknownProject }
        if managed[projectID] != nil {
            try? await supervisor.stop(projectID: projectID)
        }
        projects.removeAll { $0.id == projectID }
        try await persist()
        apply(lastListeners)
    }

    /// Current inputs for a project's re-approval window: compare with `project.approval`.
    public func reviewInput(projectID: UUID) async -> ScriptFingerprint.Input? {
        guard let project = row(projectID)?.project else { return nil }
        return await inputs(for: project)
    }

    /// Approves `shown` (the inputs displayed in the re-approval window), if the files still match it.
    public func approve(projectID: UUID, shown: ScriptFingerprint.Input) async throws(ProjectError) {
        guard let project = row(projectID)?.project else { throw .unknownProject }
        let current = await inputs(for: project)
        guard current == shown else { throw .changedWhileReviewing }
        let approval = await gate.approve(current)
        update(projectID) { row in
            row.project.approval = approval
            if row.state == .needsReapproval { row.state = .stopped }
        }
        try await persist()
    }

    /// Recomputes every idle project's fingerprint from its files and flags changed ones.
    /// Called at launch and whenever the menu opens; the gate checks again before every start.
    public func refreshApprovals() async {
        for row in projects where row.state.isIdle {
            let current = await inputs(for: row.project)
            let approved = await gate.isApproved(row.project, current: current)
            update(row.id) { row in
                guard row.state.isIdle else { return }
                if !approved {
                    row.state = .needsReapproval
                } else if row.state == .needsReapproval {
                    row.state = .stopped
                }
            }
        }
    }

    public func dismissStoreIntegrityWarning() {
        storeIntegrityWarning = false
    }

    // MARK: - Starting and stopping (AGENTS.md §6)

    public enum StartError: Error, Sendable, Equatable {
        /// The fingerprint changed (or was never approved): show the re-approval window.
        case needsApproval
        case notStartable
        case failed(String)
    }

    public enum StopError: Error, Sendable, Equatable {
        case notRunning
        case failed(String)
        /// Restart in Runner: the old server's port didn't free up within 10 s, so nothing was started.
        case portStillInUse(Int)
        /// Restart in Runner: stopped, but starting through the approval gate failed or needs review.
        case restartFailed(StartError)
    }

    /// Starts a stopped or crashed project. Always goes through the approval gate, which recomputes
    /// the fingerprint from the files right now.
    public func startProject(_ projectID: UUID) async throws(StartError) {
        guard let row = row(projectID) else { throw .notStartable }
        switch row.state {
        case .stopped, .crashed: break
        case .needsReapproval: throw .needsApproval
        default: throw .notStartable
        }
        let project = row.project
        update(projectID) { $0.state = .starting }

        let current = await inputs(for: project)
        let environment = await environment(for: project)
        let outcome: ApprovalGate.StartOutcome
        do {
            outcome = try await gate.start(project, current: current, environment: environment)
        } catch {
            update(projectID) { $0.state = .stopped }
            throw .failed(Self.describe(error))
        }

        switch outcome {
        case .needsReapproval:
            update(projectID) { $0.state = .needsReapproval }
            throw .needsApproval
        case .started:
            logger.info("started a project")
            await refreshManaged()
            watchStartup()
        }
    }

    /// Stops a running project (SIGTERM, then SIGKILL after 5 s). Runner-launched servers stop by process
    /// group; servers started elsewhere (e.g. a terminal) stop per §6.5 without touching the shell.
    public func stopProject(_ projectID: UUID) async throws(StopError) {
        guard let row = row(projectID), row.state.isRunning || row.state == .starting else { throw .notRunning }
        let previous = row.state
        update(projectID) { $0.state = .stopping }

        if managed[projectID] != nil {
            do {
                try await supervisor.stop(projectID: projectID)
            } catch {
                update(projectID) { $0.state = previous }
                throw .failed(Self.describe(error))
            }
            return // The exit event moves the row to Stopped.
        }

        guard case .running(_, let listeners, _) = previous, !listeners.isEmpty else {
            update(projectID) { $0.state = previous }
            throw .notRunning
        }
        // One stop per distinct process (a server listening on v4 + v6 is one process).
        var seen = Set<pid_t>()
        for listener in listeners where seen.insert(listener.pid).inserted {
            do {
                try await supervisor.stopExternal(listener)
            } catch {
                update(projectID) { $0.state = previous }
                throw .failed(Self.describe(error))
            }
        }
        await poll() // The listener is gone: the row moves to Stopped.
    }

    /// ⌘R: restarts a Runner-managed server (stop, wait for its exit, start again through the gate),
    /// takes over a terminal-started one (Restart in Runner), or starts a stopped one.
    public func restart(_ projectID: UUID) async throws(StopError) {
        guard let row = row(projectID) else { throw .notRunning }
        if case .running(let isManaged, _, _) = row.state, !isManaged {
            try await restartInRunner(projectID)
            return
        }
        switch row.state {
        case .running, .starting:
            try await stopProject(projectID)
            // Wait for the exit event (up to the grace period plus a little) before starting again.
            let deadline = ContinuousClock.now + ProcessSupervisor.stopGracePeriod + .seconds(2)
            while ContinuousClock.now < deadline, managed[projectID] != nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            do {
                try await startProject(projectID)
            } catch {
                throw .restartFailed(error)
            }
        case .stopped, .crashed, .needsReapproval:
            do {
                try await startProject(projectID)
            } catch {
                throw .restartFailed(error)
            }
        case .stopping:
            throw .notRunning
        }
    }

    /// Restart in Runner (§6.5): stop the server started elsewhere, wait up to 10 s for its ports to
    /// free, then start the saved command through the approval gate. If the ports don't free up,
    /// report it and don't start.
    public func restartInRunner(_ projectID: UUID) async throws(StopError) {
        guard let row = row(projectID), case .running(let managed, let listeners, _) = row.state, !managed else {
            throw .notRunning
        }
        let ports = Set(listeners.map(\.port))
        try await stopProject(projectID)

        let deadline = ContinuousClock.now + ProcessSupervisor.portFreeTimeout
        var busy = ports
        while ContinuousClock.now < deadline {
            let open = Set(await scanner.scan().map(\.port))
            busy = ports.intersection(open)
            if busy.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let port = busy.min() { throw .portStillInUse(port) }

        update(projectID) { row in
            if row.state == .stopping || row.state.isRunning { row.state = .stopped }
        }
        do {
            try await startProject(projectID)
        } catch {
            throw .restartFailed(error)
        }
    }

    /// Footer "Stop All Managed Servers", and quit. Terminal-started servers are left alone.
    public func stopAllManaged() async {
        for projectID in managed.keys {
            update(projectID) { $0.state = .stopping }
        }
        await supervisor.stopAll()
    }

    /// The project's output, for the log window.
    public func logStore(for projectID: UUID) async -> LogStore? {
        await supervisor.log(for: projectID)
    }

    /// Settings › Environment.
    public func shellEnvironment() async -> ShellEnv.Capture {
        await shellEnv.capture()
    }

    public func reloadShellEnvironment() async -> ShellEnv.Capture {
        await shellEnv.reload()
    }

    static func describe(_ error: SupervisorError) -> String {
        switch error {
        case .executableNotFound(let name):
            "Couldn't find “\(name)” on your PATH. Check Settings › Environment."
        case .spawnFailed(let code), .ptyFailed(let code):
            "Couldn't start the process: \(String(cString: strerror(code)))."
        case .alreadyRunning:
            "It's already running."
        case .identityMismatch:
            "The process changed since Runner started it, so nothing was signalled. Try again in a moment."
        case .forbiddenTarget:
            "Runner won't signal that process."
        case .portStillInUse(let port):
            "Port \(port) is still in use."
        case .notImplemented:
            "Not available yet."
        }
    }

    // MARK: - Inputs and environment

    /// Fingerprint inputs from the files right now, including the version-manager wrapper (§6.1).
    func inputs(for project: Project) async -> ScriptFingerprint.Input {
        let wrapper = await wrapper(for: project)
        return await Self.currentInput(for: project, wrapper: wrapper)
    }

    /// File reads happen off the main actor.
    nonisolated static func currentInput(for project: Project, wrapper: [String]) async -> ScriptFingerprint.Input {
        ScriptResolver.currentInput(for: project, wrapper: wrapper)
    }

    /// Runs through `mise exec --` / `fnm exec --` / `asdf exec` only when the project has a marker file
    /// and that manager is installed. The shell environment is only captured when a marker exists.
    func wrapper(for project: Project) async -> [String] {
        let root = URL(fileURLWithPath: project.path, isDirectory: true)
        let present = Set(VersionManagers.table.map(\.file).filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        })
        guard !present.isEmpty else { return [] }
        let path = await shellEnv.environment()["PATH"]
        return VersionManagers.wrapper(existingFiles: present) { ExecutableResolver.find($0, path: path) != nil }
    }

    /// Captured login env + approved env files + overrides + `FORCE_COLOR=1` (§6.1). Never logged.
    func environment(for project: Project) async -> [String: String] {
        var environment = await shellEnv.environment()
        let root = URL(fileURLWithPath: project.path, isDirectory: true)
        for name in project.envFiles where !name.hasPrefix("/") && !name.split(separator: "/").contains("..") {
            environment.merge(EnvFile.values(at: root.appendingPathComponent(name))) { _, new in new }
        }
        environment.merge(project.envOverrides) { _, new in new }
        environment["FORCE_COLOR"] = "1"
        return environment
    }

    // MARK: - Persistence

    private func persist() async throws(ProjectError) {
        do {
            try await store.save(projects.map(\.project))
        } catch {
            logger.error("Failed to save project store")
            throw .storeFailed
        }
    }

    private func setLearnedPort(_ port: Int, for projectID: UUID) {
        update(projectID) { $0.project.learnedPort = port }
        Task { try? await persist() }
    }

    private func row(_ projectID: UUID) -> ProjectRow? {
        projects.first { $0.id == projectID }
    }

    private func update(_ projectID: UUID, _ change: (inout ProjectRow) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var row = projects[index]
        change(&row)
        if row != projects[index] { projects[index] = row }
    }

    // MARK: - Polling

    /// Menu open: every 2 s. Menu closed: every 15 s (§4 "Scheduling").
    public func setPolling(menuOpen: Bool) {
        if menuOpen {
            Task { await refreshApprovals() }
        }
        pollTask?.cancel()
        let interval = menuOpen ? PortScanner.Interval.active : PortScanner.Interval.idle
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await poll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func poll() async {
        let listeners = await scanner.scan()
        await supervisor.refreshIdentities()
        managed = await supervisor.snapshot()
        lastListeners = listeners
        apply(listeners)
    }

    private func refreshManaged() async {
        managed = await supervisor.snapshot()
        apply(lastListeners)
    }

    /// After a start, scan every 0.5 s for up to 60 s until the server is listening (§6.4).
    private func watchStartup() {
        startupTask?.cancel()
        startupTask = Task { [weak self] in
            for _ in 0..<120 {
                guard let self, !Task.isCancelled else { return }
                await poll()
                if !projects.contains(where: { $0.state == .starting }) { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
            // Still alive after 60 s but not listening (a worker, or a slow first build): show it as
            // running so it can be stopped; the next listener match fills in the port.
            guard let self else { return }
            for (projectID, info) in managed {
                update(projectID) { row in
                    if row.state == .starting { row.state = .running(managed: true, listeners: [], since: info.startedAt) }
                }
            }
        }
    }

    /// Splits a scan into project matches and other listeners. Only assigns observed properties when
    /// they actually change, so an idle poll doesn't re-render the menu.
    func apply(_ listeners: [Listener]) {
        let launchedGroups = Dictionary(managed.map { ($0.value.pgid, $0.key) }, uniquingKeysWith: { first, _ in first })
        let matcher = ProjectMatcher(launchedGroups: launchedGroups)
        let registered = projects.map(\.project)
        var matched: [UUID: [Listener]] = [:]
        var unmatched: [Listener] = []
        for listener in listeners {
            if let id = matcher.match(listener, projects: registered) {
                matched[id, default: []].append(listener)
            } else {
                unmatched.append(listener)
            }
        }

        let groups = ListenerGroup.group(unmatched)
        if groups != otherListeners {
            logger.debug("apply: \(listeners.count, privacy: .public) listeners → \(groups.count, privacy: .public) other rows")
            otherListeners = groups
        }

        for index in projects.indices {
            let id = projects[index].id
            let current = projects[index].state
            let info = managed[id]
            var next = current

            if let found = matched[id] {
                let isManaged = info.map { info in found.contains { $0.pgid == info.pgid } } ?? false
                let since = isManaged ? info!.startedAt : (found.map(\.startTime.date).min() ?? .now)
                if current != .stopping {
                    next = .running(managed: isManaged, listeners: found, since: since)
                }
                if isManaged, let port = found.map(\.port).min(), projects[index].project.learnedPort != port {
                    setLearnedPort(port, for: id)
                }
                let framework = found.lazy.compactMap {
                    ListenerClassifier.classify(executablePath: $0.executablePath, argv: $0.argv)
                }.first
                if let framework, projects[index].framework != framework {
                    projects[index].framework = framework
                }
            } else if let info {
                // Launched by Runner but not listening (yet, or any more).
                if current != .starting && current != .stopping {
                    next = .running(managed: true, listeners: [], since: info.startedAt)
                }
            } else if current.isRunning || (current == .stopping && info == nil) {
                next = .stopped
            }
            if next != current { projects[index].state = next }
        }
    }
}

extension ServerState {
    /// Stopped, crashed or waiting for approval: nothing running and nothing in flight.
    var isIdle: Bool {
        switch self {
        case .stopped, .crashed, .needsReapproval: true
        case .running, .starting, .stopping: false
        }
    }
}
