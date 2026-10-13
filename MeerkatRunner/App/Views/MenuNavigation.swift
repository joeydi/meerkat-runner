import AppKit
import Foundation
import Models
import SwiftUI

/// A selectable row in the dropdown (headers aren't selectable).
enum MenuRowID: Hashable {
    case project(UUID)
    case listener(String)
}

/// A row's action buttons, in on-screen (and Tab) order. Rendering and keyboard focus share these
/// lists so Tab visits exactly what's on screen.
enum RowAction: Hashable {
    case open
    case logs
    /// Only offered for servers started in Terminal: "Restart in Runner".
    case restart
    case stop
    case start
    case review
    case copyURL
    case revealFolder
    case addAsServer

    var symbol: String {
        switch self {
        case .open: "arrow.up.forward.square"
        case .logs: "text.alignleft"
        case .restart: "arrow.clockwise"
        case .stop: "stop.fill"
        case .start: "play.fill"
        case .review: "checkmark.shield"
        case .copyURL: "doc.on.doc"
        case .revealFolder: "folder"
        case .addAsServer: "plus.square"
        }
    }

    var label: String {
        switch self {
        case .open: "Open in Browser"
        case .logs: "Show Logs"
        case .restart: "Restart in Runner"
        case .stop: "Stop"
        case .start: "Start"
        case .review: "Review"
        case .copyURL: "Copy URL"
        case .revealFolder: "Reveal Folder"
        case .addAsServer: "Add as Server…"
        }
    }

    /// A project row's actions (DESIGN.md §3 `ServerRow`). `hasLogs` = Runner has output for it.
    static func forProject(state: ServerState, hasPort: Bool, hasLogs: Bool) -> [RowAction] {
        switch state {
        case .running(let managed, _, _):
            (hasPort ? [.open] : []) + (managed ? [.logs] : [.restart]) + [.stop]
        case .starting, .stopping:
            hasLogs ? [.logs] : []
        case .stopped, .crashed:
            [.logs, .start]
        case .needsReapproval:
            [.review]
        }
    }

    /// An other-listener row's actions. View-only: never Stop (AGENTS.md §1).
    static func forListener(hasFolder: Bool, canAddAsServer: Bool) -> [RowAction] {
        [.open, .copyURL] + (hasFolder ? [.revealFolder] : []) + (canAddAsServer ? [.addAsServer] : [])
    }
}

/// The element the keyboard is on (DESIGN.md §5). Tab walks every control; ↑/↓ move between rows.
enum MenuFocus: Hashable {
    case addServer
    case settings
    case filter
    case row(MenuRowID)
    case action(MenuRowID, RowAction)
    case showMore
    case footerAdd
    case footerStopAll

    /// The row this focus is on or inside; that row is highlighted and shows its actions.
    var rowID: MenuRowID? {
        switch self {
        case .row(let id), .action(let id, _): id
        default: nil
        }
    }
}

/// What a key press in the dropdown means (DESIGN.md §5). Pure, so it's unit-tested.
enum MenuKeyCommand: Equatable {
    case moveUp
    case moveDown
    /// ←/→: step between a row and its action buttons.
    case moveLeft
    case moveRight
    /// Tab / Shift-Tab: every control in order, wrapping.
    case nextFocus
    case previousFocus
    /// Return or Space: press the focused control. On a row: open a running server, start a stopped
    /// one, review one that needs approval.
    case activate
    /// ⌘.
    case stop
    /// ⌘R: restart, or Restart in Runner for a server started in Terminal.
    case restart
    /// ⌘L
    case logs
    /// ⌘C
    case copyURL
    /// ⌘,
    case settings
    /// Esc with text in the filter.
    case clearFilter
    /// Any other typed text: focus the filter and type it there.
    case type(String)
}

enum MenuNavigation {
    enum Key {
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
    }

    /// Maps a key-down to a command, or nil to let the system handle it (e.g. Esc with an empty filter
    /// closes the menu; editing keys go to the filter field).
    static func command(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        filterIsEmpty: Bool,
        filterFocused: Bool
    ) -> MenuKeyCommand? {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        switch keyCode {
        case Key.upArrow where flags.isEmpty: return .moveUp
        case Key.downArrow where flags.isEmpty: return .moveDown
        // In the filter, ←/→ move the text cursor and Space types a space.
        case Key.leftArrow where flags.isEmpty: return filterFocused ? nil : .moveLeft
        case Key.rightArrow where flags.isEmpty: return filterFocused ? nil : .moveRight
        case Key.space where flags.isEmpty: return filterFocused ? nil : .activate
        case Key.tab where flags.isEmpty: return .nextFocus
        case Key.tab where flags == .shift: return .previousFocus
        case Key.returnKey where flags.isEmpty, Key.keypadEnter where flags.isEmpty: return .activate
        case Key.escape where flags.isEmpty: return filterIsEmpty ? nil : .clearFilter
        default: break
        }

        let characters = characters ?? ""
        if flags == .command {
            switch characters.lowercased() {
            case ".": return .stop
            case "r": return .restart
            case "l": return .logs
            // ⌘C inside the filter copies the filter's text.
            case "c": return filterFocused ? nil : .copyURL
            case ",": return .settings
            default: return nil
            }
        }

        // Plain typing (letters, digits, punctuation) jumps into the filter.
        if !filterFocused, flags.subtracting(.shift).isEmpty,
           let scalar = characters.unicodeScalars.first, characters.unicodeScalars.count == 1,
           !CharacterSet.controlCharacters.contains(scalar),
           !CharacterSet.whitespaces.contains(scalar),
           scalar.value < 0xF700 || scalar.value > 0xF8FF { // function / arrow keys
            return .type(characters)
        }
        return nil
    }

    /// The next selection after moving by `delta`, clamped to the list. With nothing selected, Down
    /// selects the first row and Up the last.
    static func move(_ selection: MenuRowID?, in rows: [MenuRowID], by delta: Int) -> MenuRowID? {
        guard !rows.isEmpty else { return nil }
        guard let selection, let index = rows.firstIndex(of: selection) else {
            return delta >= 0 ? rows.first : rows.last
        }
        return rows[min(max(index + delta, 0), rows.count - 1)]
    }

    /// Whether pressing Return / Space on `focus` takes you somewhere else (the browser, a window,
    /// Finder), so the menu should close first. Start, stop, copy, Show more and Stop All keep it
    /// open so you can see the result.
    /// - Parameter projectState: the focused project row's state, for a row's own primary action.
    static func activationLeavesMenu(_ focus: MenuFocus?, projectState: ServerState?) -> Bool {
        switch focus {
        case nil, .filter, .showMore, .footerStopAll:
            return false
        case .addServer, .footerAdd, .settings:
            return true
        case .row(.listener):
            return true // opens in the browser
        case .row(.project):
            switch projectState {
            case .running, .needsReapproval: return true // open in browser / review
            default: return false // start
            }
        case .action(_, let action):
            return [.open, .logs, .review, .revealFolder, .addAsServer].contains(action)
        }
    }

    /// A row as Tab sees it: the row itself, then its action buttons.
    struct FocusRow: Equatable {
        var id: MenuRowID
        var actions: [RowAction]
    }

    /// Every focusable control, in Tab order: header, filter, each row and its actions, Show more,
    /// footer.
    static func focusOrder(
        rows: [FocusRow], showsFilter: Bool, showsShowMore: Bool, canStopAll: Bool
    ) -> [MenuFocus] {
        var order: [MenuFocus] = [.addServer, .settings]
        if showsFilter { order.append(.filter) }
        for row in rows {
            order.append(.row(row.id))
            order += row.actions.map { .action(row.id, $0) }
        }
        if showsShowMore { order.append(.showMore) }
        order.append(.footerAdd)
        if canStopAll { order.append(.footerStopAll) }
        return order
    }

    /// Tab / Shift-Tab: the next control, wrapping at both ends. With no focus (or a focus that's
    /// gone), Tab starts at the top and Shift-Tab at the bottom.
    static func advance(_ focus: MenuFocus?, in order: [MenuFocus], by delta: Int) -> MenuFocus? {
        guard !order.isEmpty else { return nil }
        guard let focus, let index = order.firstIndex(of: focus) else {
            return delta >= 0 ? order.first : order.last
        }
        let count = order.count
        return order[((index + delta) % count + count) % count]
    }

    /// ←/→ inside a row: from the row into its first action, along the actions, and back out to the
    /// row. Stops at the ends.
    static func step(_ focus: MenuFocus, actions: [RowAction], by delta: Int) -> MenuFocus {
        switch focus {
        case .row(let id):
            guard delta > 0, let first = actions.first else { return focus }
            return .action(id, first)
        case .action(let id, let action):
            guard let index = actions.firstIndex(of: action) else { return .row(id) }
            let next = index + delta
            if next < 0 { return .row(id) }
            return next < actions.count ? .action(id, actions[next]) : focus
        default:
            return focus
        }
    }

    /// Where focus goes when its control disappears (a row stopped, a filter hid it, Stop All was
    /// disabled): an action falls back to its row, otherwise the nearest surviving control after it,
    /// then before it. Keeps Tab and Return working after acting from the keyboard.
    static func recover(_ focus: MenuFocus?, previous: [MenuFocus], current: [MenuFocus]) -> MenuFocus? {
        guard let focus, !current.contains(focus) else { return focus }
        if case .action(let id, _) = focus, current.contains(.row(id)) { return .row(id) }
        guard let index = previous.firstIndex(of: focus) else { return nil }
        let after = previous[(index + 1)...].first { current.contains($0) }
        let before = previous[..<index].last { current.contains($0) }
        return after ?? before
    }
}

/// The parts of a key-down the menu needs, copied out of the `NSEvent` (which isn't Sendable).
struct KeyPress: Sendable, Equatable {
    var keyCode: UInt16
    var characters: String?
    var modifierFlagsRawValue: UInt
    var windowNumber: Int

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue) }
}

/// Watches key-downs in the window that hosts it (the menu's panel) and hands them to `handler`.
/// A local monitor is used because the filter field would otherwise swallow arrows and Return.
struct KeyEventMonitor: NSViewRepresentable {
    /// Return true when the key press was handled (the event is then swallowed).
    let handler: @MainActor (KeyPress) -> Bool
    /// Told the hosting window when it changes (the menu registers it with `MenuBarToggle`).
    var onWindow: (@MainActor (NSWindow?) -> Void)?

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handler = handler
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handler = handler
        view.onWindow = onWindow
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.removeMonitor()
    }

    final class MonitorView: NSView {
        var handler: (@MainActor (KeyPress) -> Bool)?
        var onWindow: (@MainActor (NSWindow?) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let press = KeyPress(
                    keyCode: event.keyCode,
                    characters: event.charactersIgnoringModifiers,
                    modifierFlagsRawValue: event.modifierFlags.rawValue,
                    windowNumber: event.windowNumber
                )
                // Local monitors run on the main thread.
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, window.windowNumber == press.windowNumber,
                          let handler = self.handler
                    else { return false }
                    return handler(press)
                }
                return handled ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
