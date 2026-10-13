import Approval
import Detection
import Foundation
import Models

/// Recomputes a project's fingerprint inputs from its files *now* (AGENTS.md §8.2 step 1).
/// Reads files only, through the same read-only detectors used by the Add window.
public enum ScriptResolver {
    /// The detector that produced a project's command, by ID. `.custom` has none.
    static func detector(for id: DetectorID) -> (any Detector)? {
        switch id {
        case .node: NodeDetector()
        case .monorepo: MonorepoDetector()
        case .procfile: ProcfileDetector()
        case .rails: RailsDetector()
        case .django: DjangoDetector()
        case .python: PythonDetector()
        case .laravel: LaravelDetector()
        case .make, .just: MakeJustDetector()
        case .compose: ComposeDetector()
        case .static: StaticDetector()
        case .custom: nil
        }
    }

    /// Current fingerprint inputs for `project`. If the command's script can no longer be found
    /// (e.g. the `dev` script was deleted), `resolvedScript` is nil, which changes the fingerprint.
    /// - Parameter wrapper: the version-manager prefix the start would use (part of the fingerprint).
    public static func currentInput(for project: Project, wrapper: [String] = []) -> ScriptFingerprint.Input {
        let folder = URL(fileURLWithPath: project.path, isDirectory: true)
        var resolvedScript: String?
        var sourceMaterial: Data?

        if let detector = detector(for: project.detector) {
            let files = FileSnapshot.read(folder)
            let match = detector.detect(in: folder, files: files)
                .first { $0.detector == project.detector && $0.command == project.command }
            resolvedScript = match?.resolvedScript
            // Compose runs whatever the compose file says, so the whole file is fingerprinted.
            if project.detector == .compose, let source = match?.source {
                sourceMaterial = files.data(source)
            }
        }
        return ScriptFingerprint.Input(
            project: project, resolvedScript: resolvedScript, sourceMaterial: sourceMaterial, wrapper: wrapper
        )
    }
}
