import AppKit
@testable import MeerkatRunner
import XCTest

final class MenuNavigationTests: XCTestCase {
    private func command(
        _ keyCode: UInt16, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = [],
        filterIsEmpty: Bool = true, filterFocused: Bool = false
    ) -> MenuKeyCommand? {
        MenuNavigation.command(
            keyCode: keyCode, characters: characters, modifiers: modifiers,
            filterIsEmpty: filterIsEmpty, filterFocused: filterFocused
        )
    }

    func testArrowsAndReturn() {
        XCTAssertEqual(command(MenuNavigation.Key.upArrow), .moveUp)
        XCTAssertEqual(command(MenuNavigation.Key.downArrow), .moveDown)
        XCTAssertEqual(command(MenuNavigation.Key.returnKey, "\r"), .primary)
        XCTAssertEqual(command(MenuNavigation.Key.keypadEnter), .primary)
        // Arrows still navigate while typing in the filter.
        XCTAssertEqual(command(MenuNavigation.Key.downArrow, filterFocused: true), .moveDown)
    }

    func testCommandShortcuts() {
        XCTAssertEqual(command(47, ".", .command), .stop)
        XCTAssertEqual(command(15, "r", .command), .restart)
        XCTAssertEqual(command(37, "l", .command), .logs)
        XCTAssertEqual(command(8, "c", .command), .copyURL)
        XCTAssertEqual(command(43, ",", .command), .settings)
        // ⌘N belongs to the footer's keyboard shortcut.
        XCTAssertNil(command(45, "n", .command))
        // ⌘C in the filter copies the filter's own text.
        XCTAssertNil(command(8, "c", .command, filterFocused: true))
    }

    func testEscapeClearsFilterThenLetsTheMenuClose() {
        XCTAssertEqual(command(MenuNavigation.Key.escape, filterIsEmpty: false), .clearFilter)
        XCTAssertNil(command(MenuNavigation.Key.escape, filterIsEmpty: true))
    }

    func testTypingJumpsIntoTheFilter() {
        XCTAssertEqual(command(0, "a"), .type("a"))
        XCTAssertEqual(command(0, "A", .shift), .type("A"))
        XCTAssertEqual(command(18, "3"), .type("3"))
        // Already in the filter: the field handles it.
        XCTAssertNil(command(0, "a", filterFocused: true))
        // Control-modified and function keys are not typing.
        XCTAssertNil(command(0, "a", .control))
        XCTAssertNil(command(122, "\u{F704}")) // F1
    }

    func testMoveClampsAndStartsAtTheEnds() {
        let a = MenuRowID.project(UUID())
        let b = MenuRowID.listener("10:3000")
        let c = MenuRowID.listener("20:5173")
        let rows = [a, b, c]
        XCTAssertEqual(MenuNavigation.move(nil, in: rows, by: 1), a)
        XCTAssertEqual(MenuNavigation.move(nil, in: rows, by: -1), c)
        XCTAssertEqual(MenuNavigation.move(a, in: rows, by: 1), b)
        XCTAssertEqual(MenuNavigation.move(c, in: rows, by: 1), c)
        XCTAssertEqual(MenuNavigation.move(a, in: rows, by: -1), a)
        // A selection that scrolled out of the list (e.g. filtered away) restarts at the ends.
        XCTAssertEqual(MenuNavigation.move(.project(UUID()), in: rows, by: 1), a)
        XCTAssertNil(MenuNavigation.move(a, in: [], by: 1))
    }
}
