import Foundation

/// Resolves `argv[0]` to an executable path ourselves, against the final PATH (AGENTS.md §6.2).
/// Never goes through a shell.
public enum ExecutableResolver {
    /// - `/abs/path` → as is
    /// - `bin/dev`, `./x`, `.venv/bin/python` (contains `/`) → relative to the project folder
    /// - `npm` → first executable match on `path`
    public static func resolve(_ name: String, cwd: String, path: String?) -> String? {
        if name.hasPrefix("/") {
            return isExecutable(name) ? name : nil
        }
        if name.contains("/") {
            let candidate = (URL(fileURLWithPath: cwd).appendingPathComponent(name).standardizedFileURL).path
            return isExecutable(candidate) ? candidate : nil
        }
        return find(name, path: path)
    }

    /// First executable named `name` in a colon-separated PATH.
    public static func find(_ name: String, path: String?) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for directory in (path ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let candidate = "\(directory)/\(name)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
