import AppKit
import Foundation

/// A selectable row in the dropdown (headers aren't selectable).
enum MenuRowID: Hashable {
    case project(UUID)
    case listener(String)
}

/// What a key press in the dropdown means (DESIGN.md §5). Pure, so it's unit-tested.
enum MenuKeyCommand: Equatable {
    case moveUp
    case moveDown
    /// Return: open a running server, start a stopped one, review one that needs approval.
    case primary
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
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
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
        case Key.returnKey where flags.isEmpty, Key.keypadEnter where flags.isEmpty: return .primary
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

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handler = handler
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.removeMonitor()
    }

    final class MonitorView: NSView {
        var handler: (@MainActor (KeyPress) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
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
