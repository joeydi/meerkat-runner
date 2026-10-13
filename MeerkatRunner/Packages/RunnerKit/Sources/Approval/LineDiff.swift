import Foundation

/// Line diff for the re-approval window (AGENTS.md §8.2, §9.3). Longest-common-subsequence based;
/// inputs are short (a command plus a script), so the O(n·m) table is fine.
public enum LineDiff {
    public enum Line: Equatable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// Beyond this many lines per side, skip the table and show everything as removed then added.
    static let maxLines = 400

    public static func diff(old: [String], new: [String]) -> [Line] {
        guard old.count <= maxLines, new.count <= maxLines else {
            return old.map(Line.removed) + new.map(Line.added)
        }
        // lcs[i][j] = length of the LCS of old[i...] and new[j...]
        var lcs = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                lcs[i][j] = old[i] == new[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var result: [Line] = []
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                result.append(.same(old[i]))
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(.removed(old[i]))
                i += 1
            } else {
                result.append(.added(new[j]))
                j += 1
            }
        }
        result += old[i...].map(Line.removed)
        result += new[j...].map(Line.added)
        return result
    }

    /// What the user approves: the command line, then the resolved script's lines.
    public static func approvalLines(command: String, resolvedScript: String?) -> [String] {
        ["$ " + command] + (resolvedScript.map { $0.components(separatedBy: .newlines) } ?? [])
    }
}
