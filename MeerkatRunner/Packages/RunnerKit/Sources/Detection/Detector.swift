import Foundation
import Models

/// A read-only detector (AGENTS.md §5). Detectors are pure functions of file contents:
/// they MUST NOT execute anything, spawn processes, or touch the network (§8.1 rule 1).
public protocol Detector: Sendable {
    static var id: DetectorID { get }
    func detect(in folder: URL, files: FileSnapshot) -> [Proposal]
}

/// All detectors run for "Add server from folder". Order doesn't matter; results are ranked.
public enum Detectors {
    public static let all: [any Detector] = [
        NodeDetector(),
        MonorepoDetector(),
        ProcfileDetector(),
        RailsDetector(),
        DjangoDetector(),
        PythonDetector(),
        LaravelDetector(),
        MakeJustDetector(),
        ComposeDetector(),
        StaticDetector(),
    ]
}
