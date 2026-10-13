import Approval
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

    private let scanner: PortScanner
    private let store: ProjectStore
    private let supervisor: ProcessSupervisor
    private let gate: ApprovalGate
    @ObservationIgnored private var pollTask: Task<Void, Never>?
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
        defaults: UserDefaults = .standard
    ) {
        self.scanner = scanner
        self.store = store
        self.supervisor = supervisor
        gate = ApprovalGate(supervisor: supervisor)
        self.defaults = defaults
        // Both default to on.
        hideSystemListeners = defaults.object(forKey: Keys.hideSystemListeners) as? Bool ?? true
        hideAppListeners = defaults.object(forKey: Keys.hideAppListeners) as? Bool ?? true
    }

    // MARK: - Derived

    public var runningRows: [ProjectRow] {
        projects.filter { $0.state.isRunning }.sorted { $0.project.name < $1.project.name }
    }

    public var needsApprovalRows: [ProjectRow] {
        projects.filter { $0.state == .needsReapproval }
    }

    public var stoppedRows: [ProjectRow] {
        projects.filter { row in
            switch row.state {
            case .stopped, .crashed, .starting, .stopping: return true
            case .running, .needsReapproval: return false
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
    public var runningCount: Int { runningRows.count }

    // MARK: - Lifecycle

    /// Loads the store and starts polling. Call once at launch.
    public func start() async {
        logger.info("registry starting")
        await loadStore()
        // TODO(v0.2 step 3): re-adopt records from runtime.json whose PID + start time still match (§6.7).
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
        let current = await Self.currentInput(for: project)
        guard current.resolvedScript == shownScript else { throw .changedWhileReviewing }
        project.approval = await gate.approve(current)

        projects.append(ProjectRow(project: project, state: .stopped))
        do {
            try await persist()
        } catch {
            projects.removeAll { $0.id == project.id }
            throw error
        }
    }

    public func remove(projectID: UUID) async throws(ProjectError) {
        guard projects.contains(where: { $0.id == projectID }) else { throw .unknownProject }
        // TODO(v0.2 step 3): offer to stop it first if Runner launched it.
        projects.removeAll { $0.id == projectID }
        try await persist()
    }

    /// Current inputs for a project's re-approval window: compare with `project.approval`.
    public func reviewInput(projectID: UUID) async -> ScriptFingerprint.Input? {
        guard let project = projects.first(where: { $0.id == projectID })?.project else { return nil }
        return await Self.currentInput(for: project)
    }

    /// Approves `shown` (the inputs displayed in the re-approval window), if the files still match it.
    public func approve(projectID: UUID, shown: ScriptFingerprint.Input) async throws(ProjectError) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw .unknownProject }
        let current = await Self.currentInput(for: projects[index].project)
        guard current == shown else { throw .changedWhileReviewing }
        projects[index].project.approval = await gate.approve(current)
        if projects[index].state == .needsReapproval { projects[index].state = .stopped }
        try await persist()
    }

    /// Recomputes every stopped project's fingerprint from its files and flags changed ones.
    /// Called at launch and whenever the menu opens; the gate checks again before every start.
    public func refreshApprovals() async {
        for row in projects where !row.state.isRunning {
            let current = await Self.currentInput(for: row.project)
            let approved = await gate.isApproved(row.project, current: current)
            guard let index = projects.firstIndex(where: { $0.id == row.id }), !projects[index].state.isRunning else {
                continue
            }
            let next: ServerState = approved
                ? (projects[index].state == .needsReapproval ? .stopped : projects[index].state)
                : .needsReapproval
            if next != projects[index].state { projects[index].state = next }
        }
    }

    public func dismissStoreIntegrityWarning() {
        storeIntegrityWarning = false
    }

    /// File reads happen off the main actor.
    nonisolated static func currentInput(for project: Project) async -> ScriptFingerprint.Input {
        ScriptResolver.currentInput(for: project)
    }

    private func persist() async throws(ProjectError) {
        do {
            try await store.save(projects.map(\.project))
        } catch {
            logger.error("Failed to save project store")
            throw .storeFailed
        }
    }

    /// Menu open: every 2 s. Menu closed: every 15 s (§4 "Scheduling").
    public func setPolling(menuOpen: Bool) {
        if menuOpen {
            Task { await refreshApprovals() }
        }
        pollTask?.cancel()
        let interval = menuOpen ? PortScanner.Interval.active : PortScanner.Interval.idle
        pollTask = Task { [weak self, scanner] in
            while !Task.isCancelled {
                let listeners = await scanner.scan()
                guard let self else { return }
                apply(listeners)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Splits a scan into project matches and other listeners. Only assigns observed properties when
    /// they actually change, so an idle poll doesn't re-render the menu.
    ///
    /// TODO(v0.2): pass supervisor/runtime.json PGIDs to the matcher, mark those rows `managed`, and keep
    /// `.starting` / `.stopping` / `.crashed` states owned by the supervisor.
    func apply(_ listeners: [Listener]) {
        let matcher = ProjectMatcher()
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
            let current = projects[index].state
            let next: ServerState
            if let found = matched[projects[index].id] {
                let since = found.map(\.startTime.date).min() ?? .now
                next = .running(managed: false, listeners: found, since: since)
            } else if current.isRunning {
                next = .stopped
            } else {
                next = current
            }
            if next != current { projects[index].state = next }
        }
    }
}
