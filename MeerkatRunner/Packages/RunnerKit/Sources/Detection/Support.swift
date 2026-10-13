import Foundation

/// Splits simple command lines into argv without a shell (AGENTS.md §8.1 rule 3).
public enum ShellWords {
    /// Characters that mean the line needs a shell to mean what it says.
    static let metacharacters: Set<Character> = [
        "|", "&", ";", "<", ">", "(", ")", "$", "`", "*", "?", "[", "]", "{", "}", "~", "#", "!", "\\", "\n",
    ]

    /// Returns argv for a simple command, or nil when it needs a shell: pipes, redirects, variables,
    /// globs, unbalanced quotes, or a leading `NAME=value` assignment.
    public static func split(_ line: String) -> [String]? {
        var args: [String] = []
        var current = ""
        var hasToken = false
        var inSingle = false
        var inDouble = false

        for character in line {
            if inSingle {
                if character == "'" { inSingle = false } else { current.append(character) }
                continue
            }
            if inDouble {
                switch character {
                case "\"": inDouble = false
                case "$", "`", "\\": return nil
                default: current.append(character)
                }
                continue
            }
            switch character {
            case "'":
                inSingle = true
                hasToken = true
            case "\"":
                inDouble = true
                hasToken = true
            case " ", "\t":
                if hasToken {
                    args.append(current)
                    current = ""
                    hasToken = false
                }
            default:
                if metacharacters.contains(character) { return nil }
                current.append(character)
                hasToken = true
            }
        }
        if inSingle || inDouble { return nil }
        if hasToken { args.append(current) }
        guard let first = args.first, !first.contains("=") else { return nil }
        return args
    }
}

/// npm / yarn / bun `workspaces` and `pnpm-workspace.yaml` handling.
enum Workspaces {
    static let limit = 64

    static func patterns(packageJSON: [String: Any]?, pnpmWorkspace: String?) -> [String] {
        var result: [String] = []
        if let list = packageJSON?["workspaces"] as? [String] {
            result += list
        } else if let object = packageJSON?["workspaces"] as? [String: Any], let list = object["packages"] as? [String] {
            result += list
        }
        if let yaml = pnpmWorkspace {
            result += pnpmPackages(yaml)
        }
        return result
    }

    /// Reads the `packages:` list from `pnpm-workspace.yaml` (block style only).
    static func pnpmPackages(_ yaml: String) -> [String] {
        var inPackages = false
        var packages: [String] = []
        for raw in yaml.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indented = line.first == " " || line.first == "\t"
            if !indented && !trimmed.hasPrefix("-") {
                inPackages = trimmed.hasPrefix("packages:")
                continue
            }
            if inPackages, trimmed.hasPrefix("-") {
                let value = trimmed.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                if !value.isEmpty { packages.append(value) }
            }
        }
        return packages
    }

    /// Expands `dir`, `dir/*` and `dir/**` (one level) to existing directories inside `folder`.
    /// Negations, absolute paths and `..` are ignored.
    static func resolve(_ patterns: [String], in folder: URL) -> [String] {
        let fm = FileManager.default
        func isDirectory(_ relative: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: folder.appendingPathComponent(relative).path, isDirectory: &isDir) && isDir.boolValue
        }

        var dirs = Set<String>()
        for raw in patterns where !raw.hasPrefix("!") {
            var pattern = raw
            while pattern.hasPrefix("./") { pattern.removeFirst(2) }
            while pattern.hasSuffix("/") { pattern.removeLast() }
            guard !pattern.isEmpty, !pattern.hasPrefix("/"), !pattern.split(separator: "/").contains("..") else { continue }

            if pattern.hasSuffix("/*") || pattern.hasSuffix("/**"), let slash = pattern.lastIndex(of: "/") {
                let parent = String(pattern[..<slash])
                guard !parent.contains("*") else { continue }
                let children = (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent(parent).path)) ?? []
                for child in children.sorted() where !child.hasPrefix(".") && child != "node_modules" {
                    let relative = "\(parent)/\(child)"
                    if isDirectory(relative) { dirs.insert(relative) }
                }
            } else if !pattern.contains("*"), isDirectory(pattern) {
                dirs.insert(pattern)
            }
            if dirs.count >= limit { break }
        }
        return Array(dirs.sorted().prefix(limit))
    }
}

/// `.env` files: names and variable *names* only. Values are never displayed or logged (§8.1 rule 5).
public enum EnvFile {
    /// Preferred order when several exist.
    static let preferredOrder = [".env.local", ".env.development.local", ".env.development", ".env"]
    static let ignoredSuffixes = [".example", ".sample", ".template", ".dist"]

    /// Env files at the top level of a folder, most specific first. Excludes `.envrc` and examples.
    public static func candidates(topLevel: Set<String>) -> [String] {
        let names = topLevel.filter { name in
            name.hasPrefix(".env") && name != ".envrc" && !ignoredSuffixes.contains { name.hasSuffix($0) }
        }
        return names.sorted { lhs, rhs in
            let left = preferredOrder.firstIndex(of: lhs) ?? preferredOrder.count
            let right = preferredOrder.firstIndex(of: rhs) ?? preferredOrder.count
            return left == right ? lhs < rhs : left < right
        }
    }

    /// Variable names declared in an env file (`NAME=…` or `export NAME=…`).
    public static func keys(in contents: String) -> [String] {
        contents.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "="), equals != line.startIndex else { return nil }
            let name = line[..<equals]
            guard let first = name.first, first == "_" || first.isLetter,
                  name.allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber })
            else { return nil }
            return String(name)
        }
    }

    /// Counts variables in an env file on disk (capped read). nil if unreadable.
    public static func keyCount(at url: URL) -> Int? {
        guard case .contents(let data)? = FileSnapshot.readEntry(url),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return keys(in: text).count
    }
}

/// Picks the Python interpreter for a project (AGENTS.md §5 Django row).
enum PythonInterpreter {
    static func path(in files: FileSnapshot) -> String {
        if files.exists(".venv/bin/python") { return ".venv/bin/python" }
        if files.exists("venv/bin/python") { return "venv/bin/python" }
        return "python3"
    }
}

extension String {
    /// Script bodies shown for approval: trailing whitespace trimmed so diffs aren't noisy.
    var trimmedScript: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
