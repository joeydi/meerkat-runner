import AppKit
import Carbon.HIToolbox

/// A user-chosen keyboard shortcut that opens the menu from anywhere (AGENTS.md §7). Default: none.
///
/// Stored as the key code plus modifiers, with the key's name captured when it was recorded so the
/// Settings field can show it without a keyboard-layout lookup.
struct HotKey: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value, limited to ⌃ ⌥ ⇧ ⌘.
    var modifierFlags: UInt
    /// e.g. "R", "Space", "F5".
    var keyName: String

    static let defaultsKey = "openMenuHotKey"
    static var allowedModifiers: NSEvent.ModifierFlags { [.control, .option, .shift, .command] }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    /// `⌃⌥⌘R`, in the order macOS menus use.
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyName
    }

    /// Carbon's modifier mask for `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var mask = 0
        if modifiers.contains(.command) { mask |= cmdKey }
        if modifiers.contains(.option) { mask |= optionKey }
        if modifiers.contains(.control) { mask |= controlKey }
        if modifiers.contains(.shift) { mask |= shiftKey }
        return UInt32(mask)
    }

    enum RecordResult: Equatable {
        case recorded(HotKey)
        /// Esc: stop recording, keep the old shortcut.
        case cancel
        /// Delete: remove the shortcut.
        case clear
        /// Not usable on its own (e.g. a plain letter); keep listening.
        case invalid(String)
    }

    /// Interprets a key press while the Settings field is recording. Pure, so it's unit-tested.
    /// A shortcut needs ⌘, ⌥ or ⌃ (⇧ alone would steal typing), except function keys, which may be bare.
    static func record(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> RecordResult {
        let flags = modifiers.intersection(allowedModifiers)
        if flags.isEmpty {
            switch keyCode {
            case UInt16(kVK_Escape): return .cancel
            case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete): return .clear
            default: break
            }
        }
        guard let name = keyName(keyCode: keyCode, characters: characters) else {
            return .invalid("That key can't be used for a shortcut.")
        }
        let isFunctionKey = functionKeys[keyCode] != nil
        guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else {
            return .invalid("Include ⌘, ⌥ or ⌃.")
        }
        return .recorded(HotKey(keyCode: keyCode, modifierFlags: flags.rawValue, keyName: name))
    }

    static let functionKeys: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]

    static let namedKeys: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "⎋",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘", UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
    ]

    /// Display name for a key, or nil for keys that can't be shortcuts (modifier keys alone, etc.).
    static func keyName(keyCode: UInt16, characters: String?) -> String? {
        if let name = functionKeys[keyCode] ?? namedKeys[keyCode] { return name }
        guard let characters, characters.count == 1, let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.whitespaces.contains(scalar),
              scalar.value < 0xF700 || scalar.value > 0xF8FF
        else { return nil }
        return characters.uppercased()
    }

    // MARK: - Persistence

    static func load(from defaults: UserDefaults = .standard) -> HotKey? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(HotKey.self, from: $0) }
    }

    static func save(_ hotKey: HotKey?, to defaults: UserDefaults = .standard) {
        if let hotKey, let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}

/// Registers the open-menu shortcut system-wide with Carbon's `RegisterEventHotKey`, which needs no
/// Accessibility or Input Monitoring permission and only ever sees this one key combination (it is
/// not a keyboard monitor).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    enum RegisterError: Error, Equatable {
        /// Another app already registered the same combination.
        case inUse
        case failed(OSStatus)
    }

    /// Called on the main actor when the shortcut is pressed.
    var onPress: (@MainActor () -> Void)?
    private(set) var current: HotKey?
    private var reference: EventHotKeyRef?
    private var handlerInstalled = false

    private static let signature: OSType = 0x4D4B_5252 // "MKRR"

    private init() {}

    /// Replaces the registered shortcut. nil unregisters it.
    func register(_ hotKey: HotKey?) throws(RegisterError) {
        unregister()
        guard let hotKey else { return }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(hotKey.keyCode), hotKey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            throw status == OSStatus(eventHotKeyExistsErr) ? .inUse : .failed(status)
        }
        reference = ref
        current = hotKey
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        current = nil
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                // Carbon delivers application-target events on the main thread.
                MainActor.assumeIsolated { HotKeyCenter.shared.onPress?() }
                return noErr
            },
            1, &eventType, nil, nil
        )
        handlerInstalled = status == noErr
    }
}

/// Opens or closes the menu bar dropdown as if its icon were clicked. SwiftUI's `MenuBarExtra` has no
/// API for this, so it clicks the status item's button.
@MainActor
enum MenuBarToggle {
    static func toggle() {
        for window in NSApp.windows where String(describing: type(of: window)).contains("NSStatusBarWindow") {
            if let button = statusButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusButton(in: subview) { return button }
        }
        return nil
    }
}
