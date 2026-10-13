import Foundation
import Models

/// Reads `artisan`, `composer.json`. Proposes `php artisan serve`.
///
/// Pure function of `files`: never executes, spawns, or fetches anything (AGENTS.md §8.1).
public struct LaravelDetector: Detector {
    public static let id: DetectorID = .laravel

    public init() {}

    public func detect(in folder: URL, files: FileSnapshot) -> [Proposal] {
        guard files.exists("artisan"),
              let require = files.json("composer.json")?["require"] as? [String: Any],
              require["laravel/framework"] != nil
        else { return [] }
        return [Proposal(
            detector: .laravel,
            label: "php artisan serve",
            command: .argv(["php", "artisan", "serve"]),
            source: "artisan",
            framework: "Laravel",
            predictedPort: 8000,
            confidence: 90
        )]
    }
}
