import Foundation

/// Runtime state of a registered project (AGENTS.md §3).
public enum ServerState: Sendable, Equatable {
    /// `managed` = Runner launched it; `false` = matched a server started elsewhere (e.g. a terminal).
    case running(managed: Bool, listeners: [Listener], since: Date)
    case starting
    case stopping
    case stopped
    case crashed(exitCode: Int32, at: Date)
    case needsReapproval

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isManaged: Bool {
        if case .running(let managed, _, _) = self { return managed }
        return false
    }
}

/// One row in the dropdown's Running / Stopped / Needs approval sections.
public struct ProjectRow: Identifiable, Sendable, Equatable {
    public var project: Project
    public var state: ServerState
    /// Detected framework label, e.g. "Next.js".
    public var framework: String?

    public var id: UUID { project.id }

    public init(project: Project, state: ServerState, framework: String? = nil) {
        self.project = project
        self.state = state
        self.framework = framework
    }
}
