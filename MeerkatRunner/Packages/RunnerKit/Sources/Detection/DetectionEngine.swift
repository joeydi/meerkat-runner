import Foundation
import Models

/// Runs every detector concurrently against a folder and returns ranked proposals (AGENTS.md §5).
public enum DetectionEngine {
    public static func detect(in folder: URL, detectors: [any Detector] = Detectors.all) async -> [Proposal] {
        let snapshot = FileSnapshot.read(folder)
        let proposals = await withTaskGroup(of: [Proposal].self) { group in
            for detector in detectors {
                group.addTask { detector.detect(in: folder, files: snapshot) }
            }
            var all: [Proposal] = []
            for await result in group { all.append(contentsOf: result) }
            return all
        }
        return rank(proposals)
    }

    /// Highest confidence first; ties broken by label for a stable order.
    public static func rank(_ proposals: [Proposal]) -> [Proposal] {
        proposals.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.label < $1.label
        }
    }
}
