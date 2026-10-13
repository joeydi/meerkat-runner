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
    /// Unmatched listeners. View-only: Runner never stops these.
    public private(set) var otherListeners: [Listener] = []
    /// Set when the store's MAC failed and approvals were cleared; the UI shows a one-time warning.
    public private(set) var storeIntegrityWarning = false
    /// Settings: hide `SystemListeners` from Other listeners.
    public var hideSystemListeners = true

    private let scanner: PortScanner
    private let store: ProjectStore
    private let supervisor: ProcessSupervisor
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let logger = RunnerLog.logger(category: "registry")

    public init(
        scanner: PortScanner = PortScanner(),
        store: ProjectStore = ProjectStore(),
        supervisor: ProcessSupervisor = ProcessSupervisor()
    ) {
        self.scanner = scanner
        self.store = store
        self.supervisor = supervisor
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

    public var visibleOtherListeners: [Listener] {
        let listeners = hideSystemListeners
            ? otherListeners.filter { !SystemListeners.isSystemListener($0) }
            : otherListeners
        return listeners.sorted { $0.port < $1.port }
    }

    /// Menu bar badge: running count (hidden at 0).
    public var runningCount: Int { runningRows.count }

    // MARK: - Lifecycle

    /// Loads the store and starts polling. Call once at launch.
    public func start() async {
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

    /// TODO(v0.1/v0.2): match listeners to projects with `ProjectMatcher` (using supervisor PGIDs),
    /// de-duplicate v4+v6 per port, and update row states.
    private func apply(_ listeners: [Listener]) {
        otherListeners = listeners
    }
}
