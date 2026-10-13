import Foundation

/// Redacts secret-looking values on display and export (AGENTS.md §6.3).
/// Applies to `KEY=value` and `"key": "value"` shapes where the key matches
/// `(?i)(key|token|secret|password|passwd|auth|cookie|session)`.
public enum Redactor {
    public static let mask = "[redacted]"

    private static let keyWords = "key|token|secret|password|passwd|auth|cookie|session"

    // `API_KEY=abc`, `export SESSION_SECRET="abc def"`
    nonisolated(unsafe) private static let assignment = try! NSRegularExpression(
        pattern: #"(?i)\b([A-Za-z0-9_.-]*(?:"# + keyWords + #")[A-Za-z0-9_.-]*)=("[^"]*"|'[^']*'|[^\s"'&,;]+)"#
    )

    // `"apiKey": "abc"`
    nonisolated(unsafe) private static let jsonPair = try! NSRegularExpression(
        pattern: #"(?i)("[^"]*(?:"# + keyWords + #")[^"]*"\s*:\s*)"(?:[^"\\]|\\.)*""#
    )

    public static func redact(_ text: String) -> String {
        var result = text
        result = replace(assignment, in: result, template: "$1=" + mask)
        result = replace(jsonPair, in: result, template: "$1\"" + mask + "\"")
        return result
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
