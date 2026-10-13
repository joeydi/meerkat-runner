import Foundation
import Models

/// Reads `artisan`, `composer.json`. Proposes `php artisan serve`.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct LaravelDetector: Detector {
    public static let id: DetectorID = .laravel

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        // TODO(v0.2): implement per AGENTS.md §5 detector table; add fixtures + expected.json in Tests/Fixtures.
        []
    }
}
