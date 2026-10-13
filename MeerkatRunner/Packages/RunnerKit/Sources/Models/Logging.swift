import os

/// Shared `os.Logger` subsystem. Paths are `.private` by default; commands and env values are never logged.
public enum RunnerLog {
    public static let subsystem = "us.okayplus.meerkat-runner"

    public static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
