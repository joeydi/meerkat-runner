import Foundation

/// A start command proposed by a detector for the Add sheet (AGENTS.md §5).
public struct Proposal: Sendable, Equatable {
    public var detector: DetectorID
    /// e.g. "pnpm dev"
    public var label: String
    public var command: LaunchCommand
    /// e.g. "next dev --turbopack", including pre/post hooks when present.
    public var resolvedScript: String?
    /// e.g. "package.json"
    public var source: String
    /// e.g. "Next.js 15"
    public var framework: String?
    public var predictedPort: Int?
    /// Ranking only; higher sorts first.
    public var confidence: Int
    /// e.g. "needs a build first"
    public var notes: [String]

    public init(
        detector: DetectorID,
        label: String,
        command: LaunchCommand,
        resolvedScript: String? = nil,
        source: String,
        framework: String? = nil,
        predictedPort: Int? = nil,
        confidence: Int,
        notes: [String] = []
    ) {
        self.detector = detector
        self.label = label
        self.command = command
        self.resolvedScript = resolvedScript
        self.source = source
        self.framework = framework
        self.predictedPort = predictedPort
        self.confidence = confidence
        self.notes = notes
    }
}
