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
        do {
            let result = try await store.load()
            projects = result.projects.map { ProjectRow(project: $0, state: .stopped) }
            storeIntegrityWarning = !result.integrityOK
        } catch {
            logger.error("Failed to load project store")
        }
        // TODO(v0.2): re-adopt records from runtime.json whose PID + start time still match (§6.7).
        setPolling(menuOpen: false)
    }

    /// Menu open: every 2 s. Menu closed: every 15 s (§4 "Scheduling").
    public func setPolling(menuOpen: Bool) {
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
