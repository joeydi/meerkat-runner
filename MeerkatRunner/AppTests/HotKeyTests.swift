import AppKit
import Carbon.HIToolbox
@testable import MeerkatRunner
import XCTest

final class HotKeyTests: XCTestCase {
    private func record(_ keyCode: Int, _ characters: String?, _ modifiers: NSEvent.ModifierFlags) -> HotKey.RecordResult {
        HotKey.record(keyCode: UInt16(keyCode), characters: characters, modifiers: modifiers)
    }

    func testRecordsShortcutsWithACommandOptionOrControl() {
        XCTAssertEqual(
            record(kVK_ANSI_R, "r", [.control, .option, .command]),
            .recorded(HotKey(keyCode: UInt16(kVK_ANSI_R), modifierFlags: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, keyName: "R"))
        )
        guard case .recorded(let hotKey) = record(kVK_Space, " ", [.option, .shift]) else {
            return XCTFail("⌥⇧Space should record")
        }
        XCTAssertEqual(hotKey.displayString, "⌥⇧Space")
        // Caps Lock and other flags are dropped.
        guard case .recorded(let capsLock) = record(kVK_ANSI_M, "m", [.command, .capsLock]) else {
            return XCTFail("⌘M should record")
        }
        XCTAssertEqual(capsLock.modifiers, .command)
    }

    func testFunctionKeysMayBeBare() {
        guard case .recorded(let hotKey) = record(kVK_F5, "\u{F708}", []) else { return XCTFail("F5 should record") }
        XCTAssertEqual(hotKey.displayString, "F5")
    }

    func testPlainOrShiftOnlyKeysAreRefused() {
        XCTAssertEqual(record(kVK_ANSI_A, "a", []), .invalid("Include ⌘, ⌥ or ⌃."))
        XCTAssertEqual(record(kVK_ANSI_A, "A", .shift), .invalid("Include ⌘, ⌥ or ⌃."))
    }

    func testEscapeCancelsAndDeleteClears() {
        XCTAssertEqual(record(kVK_Escape, "\u{1B}", []), .cancel)
        XCTAssertEqual(record(kVK_Delete, "\u{7F}", []), .clear)
        XCTAssertEqual(record(kVK_ForwardDelete, "\u{F728}", []), .clear)
    }

    func testDisplayOrderAndCarbonMask() {
        let hotKey = HotKey(
            keyCode: UInt16(kVK_ANSI_K),
            modifierFlags: NSEvent.ModifierFlags([.command, .shift, .option, .control]).rawValue,
            keyName: "K"
        )
        XCTAssertEqual(hotKey.displayString, "⌃⌥⇧⌘K")
        XCTAssertEqual(hotKey.carbonModifiers, UInt32(cmdKey | optionKey | controlKey | shiftKey))
    }

    func testPersistenceRoundTrip() throws {
        let suite = "HotKeyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(HotKey.load(from: defaults))
        let hotKey = HotKey(keyCode: UInt16(kVK_ANSI_R), modifierFlags: NSEvent.ModifierFlags.command.rawValue, keyName: "R")
        HotKey.save(hotKey, to: defaults)
        XCTAssertEqual(HotKey.load(from: defaults), hotKey)
        HotKey.save(nil, to: defaults)
        XCTAssertNil(HotKey.load(from: defaults))
    }
}
