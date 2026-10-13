import AppKit
import SwiftUI

/// Renders terminal output with SGR colours (AGENTS.md §9.4). Supports reset, bold, dim, the 8 + 8
/// bright foreground colours and default; 256-colour / RGB codes are skipped. Other escapes are dropped.
enum ANSIText {
    static func attributed(_ raw: String) -> AttributedString {
        var result = AttributedString()
        var style = Style()
        var text = Substring(raw)

        while let escape = text.firstIndex(of: "\u{1B}") {
            result += style.apply(String(text[..<escape]))
            text = text[text.index(after: escape)...]
            guard text.first == "[" else {
                // Not CSI: drop the escape and the next character.
                text = text.dropFirst()
                continue
            }
            text = text.dropFirst()
            guard let end = text.firstIndex(where: { ("@"..."~").contains($0) }) else { break }
            let parameters = text[..<end]
            if text[end] == "m" {
                style.update(with: parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 })
            }
            text = text[text.index(after: end)...]
        }
        result += style.apply(String(text))
        return result
    }

    struct Style {
        var foreground: Color?
        var bold = false
        var dim = false

        mutating func update(with codes: [Int]) {
            var index = 0
            let codes = codes.isEmpty ? [0] : codes
            while index < codes.count {
                let code = codes[index]
                switch code {
                case 0: self = Style()
                case 1: bold = true
                case 2: dim = true
                case 22: bold = false; dim = false
                case 30...37: foreground = Self.palette[code - 30]
                case 90...97: foreground = Self.bright[code - 90]
                case 39: foreground = nil
                case 38, 48:
                    // 38;5;n or 38;2;r;g;b (and background equivalents): skip their arguments.
                    if index + 1 < codes.count { index += codes[index + 1] == 5 ? 2 : 4 }
                default: break
                }
                index += 1
            }
        }

        func apply(_ text: String) -> AttributedString {
            var attributed = AttributedString(text)
            if let foreground { attributed.foregroundColor = foreground }
            if bold { attributed.font = .system(size: 12, weight: .bold, design: .monospaced) }
            if dim { attributed.foregroundColor = (foreground ?? .primary).opacity(0.6) }
            return attributed
        }

        /// System colours so both appearances stay readable.
        static let palette: [Color] = [
            .primary, Color(nsColor: .systemRed), Color(nsColor: .systemGreen), Color(nsColor: .systemOrange),
            Color(nsColor: .systemBlue), Color(nsColor: .systemPurple), Color(nsColor: .systemTeal), .secondary,
        ]
        static let bright: [Color] = [
            .secondary, Color(nsColor: .systemRed), Color(nsColor: .systemGreen), Color(nsColor: .systemYellow),
            Color(nsColor: .systemBlue), Color(nsColor: .systemPink), Color(nsColor: .systemCyan), .primary,
        ]
    }
}

enum Alerts {
    /// A plain modal alert; works even when the menu popover has closed.
    @MainActor
    static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}
