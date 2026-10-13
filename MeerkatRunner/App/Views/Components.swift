import AppKit
import Models
import SwiftUI

/// Design tokens from design-handoff/DESIGN.md §2. Prefer semantic system colours.
enum Tokens {
    static let popoverWidth: CGFloat = 360
    static let popoverMaxHeight: CGFloat = 620

    enum Font {
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let header = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let rowName = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let bodySmall = SwiftUI.Font.system(size: 12.5)
        static let label = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let meta = SwiftUI.Font.system(size: 11.5)
        static let section = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let badge = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let code = SwiftUI.Font.system(size: 12.5, design: .monospaced)
        static let port = SwiftUI.Font.system(size: 12).monospacedDigit()
    }

    enum Colors {
        static let fillControl = Color.primary.opacity(0.06)
        static let fillCode = Color.primary.opacity(0.04)
        static let statusRunning = Color(nsColor: .systemGreen)
        static let warningText = Color("WarningText")
        static let warningFill = Color("WarningFill")
        static let errorText = Color("ErrorText")
        static let diffRemovedText = Color("DiffRemovedText")
        static let diffRemovedFill = Color("DiffRemovedFill")
        static let diffAddedText = Color("DiffAddedText")
        static let diffAddedFill = Color("DiffAddedFill")
    }
}

/// 8 pt status dot (DESIGN.md §3 `StatusDot`). Hidden from accessibility; rows speak the state.
struct StatusDot: View {
    enum Kind {
        case running, transitioning, stopped, needsApproval, crashed, other
    }

    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .running:
                Circle().fill(Tokens.Colors.statusRunning)
            case .transitioning:
                // TODO: 1 s opacity pulse, off with Reduce Motion.
                Circle().fill(Tokens.Colors.statusRunning.opacity(0.5))
            case .stopped:
                Circle().strokeBorder(.tertiary, lineWidth: 1.5)
            case .needsApproval:
                Circle().fill(Tokens.Colors.warningText)
            case .crashed:
                Circle().fill(Tokens.Colors.errorText)
            case .other:
                Circle().fill(.tertiary)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

extension StatusDot.Kind {
    init(_ state: ServerState) {
        switch state {
        case .running: self = .running
        case .starting, .stopping: self = .transitioning
        case .stopped: self = .stopped
        case .crashed: self = .crashed
        case .needsReapproval: self = .needsApproval
        }
    }
}

/// DESIGN.md §3 `Badge`.
struct Badge: View {
    enum Style { case warning, neutral, accent }

    let text: String
    let style: Style
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10))
            }
            Text(text)
        }
        .font(Tokens.Font.badge)
        .foregroundStyle(foreground)
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(background, in: RoundedRectangle(cornerRadius: 4))
        .fixedSize()
    }

    private var foreground: Color {
        switch style {
        case .warning: Tokens.Colors.warningText
        case .neutral: .secondary
        case .accent: .accentColor
        }
    }

    private var background: Color {
        switch style {
        case .warning: Tokens.Colors.warningFill
        case .neutral: Tokens.Colors.fillControl
        case .accent: Color.accentColor.opacity(0.1)
        }
    }
}

/// Icon-only button. Always has a tooltip and an accessibility label (DESIGN.md §3 `IconButton`).
struct IconButton: View {
    enum Size { case row, header }

    let symbol: String
    let label: String
    var size: Size = .row
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size == .row ? 12 : 15))
                .frame(width: size == .row ? 26 : 28, height: size == .row ? 26 : 28)
                .background(size == .row ? Tokens.Colors.fillControl : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Uppercase section header (DESIGN.md §3 `SectionHeader`).
struct SectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let count { Text("\(count)") }
        }
        .font(Tokens.Font.section)
        .tracking(0.2)
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "This command runs as you…" note (DESIGN.md §3 `InfoCallout`).
struct InfoCallout: View {
    var symbol = "lock.shield"
    let text: Text

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14))
            text.font(.system(size: 12)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Colors.fillControl, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Line diff card (DESIGN.md §3 `DiffView`). The −/+ prefixes carry meaning without colour.
struct DiffView: View {
    enum Line: Hashable {
        case removed(String)
        case added(String)
        case context(String)
    }

    let title: String
    let lines: [Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Tokens.Font.label)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        row(line)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder
    private func row(_ line: Line) -> some View {
        let (prefix, text, foreground, background): (String, String, Color, Color) = switch line {
        case .removed(let text): ("\u{2212}", text, Tokens.Colors.diffRemovedText, Tokens.Colors.diffRemovedFill)
        case .added(let text): ("+", text, Tokens.Colors.diffAddedText, Tokens.Colors.diffAddedFill)
        case .context(let text): (" ", text, .primary, .clear)
        }
        Text("\(prefix) \(text)")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(background)
            .textSelection(.enabled)
    }
}

enum Format {
    /// `6m`, `41m`, `2h 14m`, `3d` (DESIGN.md §3 `ServerRow`).
    static func uptime(since date: Date, now: Date = .now) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d"
    }

    /// Abbreviates the home directory as `~`.
    static func abbreviatingHome(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Always `localhost`, never `127.0.0.1` (IPv6-only binds still work; AGENTS.md §14).
    static func localURL(port: Int) -> URL? {
        URL(string: "http://localhost:\(port)")
    }
}
