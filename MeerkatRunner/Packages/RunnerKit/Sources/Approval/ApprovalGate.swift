import Foundation
import Models
@_spi(ApprovalGate) import Supervisor

/// The only path from a detected or saved command to a running process (AGENTS.md §2, §8.2).
///
/// Every start — manual, auto-start at login, deep link, Restart in Runner — goes through
/// `start(_:current:environment:)`, which recomputes the fingerprint from current files and refuses
/// to spawn unless it equals the saved approval.
public actor ApprovalGate {
    public enum StartOutcome: Sendable {
        case started(LaunchRecord)
        /// Fingerprint differs or the project was never approved. Show the re-approval sheet (§9.3),
        /// or post a notification for auto-start.
        case needsReapproval(previous: Approval?, current: ScriptFingerprint.Input)
    }

    private let supervisor: ProcessSupervisor

    public init(supervisor: ProcessSupervisor) {
        self.supervisor = supervisor
    }

    /// Records the user's approval of exactly what they were shown.
    public func approve(_ input: ScriptFingerprint.Input, at date: Date = .now) -> Approval {
        Approval(
            fingerprint: ScriptFingerprint.compute(input),
            approvedAt: date,
            displayedCommand: input.command.displayString,
            resolvedScript: input.resolvedScript
        )
    }

    /// Whether `project` may start with the given current inputs.
    public func isApproved(_ project: Project, current: ScriptFingerprint.Input) -> Bool {
        guard let approval = project.approval else { return false }
        return approval.fingerprint == ScriptFingerprint.compute(current)
    }

    /// Starts `project` if, and only if, its current fingerprint matches its approval.
    ///
    /// - Parameters:
    ///   - current: inputs recomputed from the project's files *now* (not from the store).
    ///   - environment: final env (captured env + env files + overrides + FORCE_COLOR=1).
    public func start(
        _ project: Project,
        current: ScriptFingerprint.Input,
        environment: [String: String]
    ) async throws(SupervisorError) -> StartOutcome {
        guard current.projectPath == project.path, current.command == project.launchCommand,
              isApproved(project, current: current)
        else {
            return .needsReapproval(previous: project.approval, current: current)
        }
        let spec = LaunchSpec(
            projectID: project.id,
            command: current.command,
            workingDirectory: current.projectPath,
            environment: environment,
            wrapper: current.wrapper
        )
        return .started(try await supervisor.spawn(spec))
    }
}
