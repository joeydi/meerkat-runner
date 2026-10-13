import AppKit
@testable import MeerkatRunner
import Models
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
        XCTAssertEqual(command(MenuNavigation.Key.returnKey, "\r"), .activate)
        XCTAssertEqual(command(MenuNavigation.Key.keypadEnter), .activate)
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

    // MARK: - Tab, Space, ←/→

    func testTabAndShiftTab() {
        XCTAssertEqual(command(MenuNavigation.Key.tab, "\t"), .nextFocus)
        XCTAssertEqual(command(MenuNavigation.Key.tab, "\t", .shift), .previousFocus)
        // Tab leaves the filter too.
        XCTAssertEqual(command(MenuNavigation.Key.tab, "\t", filterFocused: true), .nextFocus)
    }

    /// Regression: Space used to be treated as typing and always landed in the filter.
    func testSpaceActivatesUnlessTypingInTheFilter() {
        XCTAssertEqual(command(MenuNavigation.Key.space, " "), .activate)
        XCTAssertNil(command(MenuNavigation.Key.space, " ", filterFocused: true))
        XCTAssertNil(command(MenuNavigation.Key.space, " ", .shift))
    }

    func testLeftRightStepUnlessTypingInTheFilter() {
        XCTAssertEqual(command(MenuNavigation.Key.leftArrow), .moveLeft)
        XCTAssertEqual(command(MenuNavigation.Key.rightArrow), .moveRight)
        XCTAssertNil(command(MenuNavigation.Key.leftArrow, filterFocused: true))
        XCTAssertNil(command(MenuNavigation.Key.rightArrow, filterFocused: true))
    }

    func testFocusOrderCoversEveryControl() {
        let project = MenuRowID.project(UUID())
        let listener = MenuRowID.listener("10:3000")
        let rows = [
            MenuNavigation.FocusRow(id: project, actions: [.open, .logs, .stop]),
            MenuNavigation.FocusRow(id: listener, actions: [.open, .copyURL]),
        ]
        XCTAssertEqual(
            MenuNavigation.focusOrder(rows: rows, showsFilter: true, showsShowMore: true, canStopAll: true),
            [
                .addServer, .settings, .filter,
                .row(project), .action(project, .open), .action(project, .logs), .action(project, .stop),
                .row(listener), .action(listener, .open), .action(listener, .copyURL),
                .showMore, .footerAdd, .footerStopAll,
            ]
        )
        XCTAssertEqual(
            MenuNavigation.focusOrder(rows: [], showsFilter: false, showsShowMore: false, canStopAll: false),
            [.addServer, .settings, .footerAdd]
        )
    }

    func testAdvanceWraps() {
        let order: [MenuFocus] = [.addServer, .settings, .footerAdd]
        XCTAssertEqual(MenuNavigation.advance(nil, in: order, by: 1), .addServer)
        XCTAssertEqual(MenuNavigation.advance(nil, in: order, by: -1), .footerAdd)
        XCTAssertEqual(MenuNavigation.advance(.addServer, in: order, by: 1), .settings)
        XCTAssertEqual(MenuNavigation.advance(.footerAdd, in: order, by: 1), .addServer)
        XCTAssertEqual(MenuNavigation.advance(.addServer, in: order, by: -1), .footerAdd)
        XCTAssertEqual(MenuNavigation.advance(.showMore, in: order, by: 1), .addServer)
        XCTAssertNil(MenuNavigation.advance(.addServer, in: [], by: 1))
    }

    func testStepWithinARow() {
        let row = MenuRowID.project(UUID())
        let actions: [RowAction] = [.open, .logs, .stop]
        XCTAssertEqual(MenuNavigation.step(.row(row), actions: actions, by: 1), .action(row, .open))
        XCTAssertEqual(MenuNavigation.step(.row(row), actions: actions, by: -1), .row(row))
        XCTAssertEqual(MenuNavigation.step(.action(row, .open), actions: actions, by: 1), .action(row, .logs))
        XCTAssertEqual(MenuNavigation.step(.action(row, .open), actions: actions, by: -1), .row(row))
        XCTAssertEqual(MenuNavigation.step(.action(row, .stop), actions: actions, by: 1), .action(row, .stop))
        XCTAssertEqual(MenuNavigation.step(.row(row), actions: [], by: 1), .row(row))
    }

    func testRecoverKeepsFocusNearby() {
        let a = MenuRowID.project(UUID())
        let b = MenuRowID.project(UUID())
        let before: [MenuFocus] = [.addServer, .row(a), .action(a, .stop), .row(b), .footerAdd, .footerStopAll]
        // Stopping a server removes its Stop button: focus falls back to the row.
        let stopped: [MenuFocus] = [.addServer, .row(a), .action(a, .start), .row(b), .footerAdd]
        XCTAssertEqual(MenuNavigation.recover(.action(a, .stop), previous: before, current: stopped), .row(a))
        // Stop All disabled: the nearest surviving control before it.
        XCTAssertEqual(MenuNavigation.recover(.footerStopAll, previous: before, current: stopped), .footerAdd)
        // A row filtered away: the next surviving control after it.
        let filtered: [MenuFocus] = [.addServer, .row(b), .footerAdd]
        XCTAssertEqual(MenuNavigation.recover(.row(a), previous: before, current: filtered), .row(b))
        XCTAssertEqual(MenuNavigation.recover(.row(b), previous: before, current: filtered), .row(b))
        XCTAssertNil(MenuNavigation.recover(nil, previous: before, current: filtered))
    }

    func testRowActionsMatchTheButtons() {
        let since = Date()
        XCTAssertEqual(
            RowAction.forProject(state: .running(managed: true, listeners: [], since: since), hasPort: true, hasLogs: true),
            [.open, .logs, .stop]
        )
        // Started in Terminal: Restart in Runner, never Logs (Runner has no output for it).
        XCTAssertEqual(
            RowAction.forProject(state: .running(managed: false, listeners: [], since: since), hasPort: true, hasLogs: false),
            [.open, .restart, .stop]
        )
        XCTAssertEqual(
            RowAction.forProject(state: .running(managed: true, listeners: [], since: since), hasPort: false, hasLogs: true),
            [.logs, .stop]
        )
        XCTAssertEqual(RowAction.forProject(state: .stopped, hasPort: true, hasLogs: false), [.logs, .start])
        XCTAssertEqual(
            RowAction.forProject(state: .crashed(exitCode: 1, at: since), hasPort: true, hasLogs: false), [.logs, .start]
        )
        XCTAssertEqual(RowAction.forProject(state: .needsReapproval, hasPort: true, hasLogs: false), [.review])
        XCTAssertEqual(RowAction.forProject(state: .starting, hasPort: true, hasLogs: true), [.logs])
        XCTAssertEqual(RowAction.forProject(state: .stopping, hasPort: true, hasLogs: false), [])
        // Other listeners are view-only: never Stop.
        XCTAssertEqual(
            RowAction.forListener(hasFolder: true, canAddAsServer: true), [.open, .copyURL, .revealFolder, .addAsServer]
        )
        XCTAssertEqual(RowAction.forListener(hasFolder: false, canAddAsServer: false), [.open, .copyURL])
    }

    func testKeyboardActionsThatGoElsewhereCloseTheMenu() {
        let project = MenuRowID.project(UUID())
        let listener = MenuRowID.listener("10:3000")
        let running = ServerState.running(managed: true, listeners: [], since: Date())
        // Somewhere else: browser, windows, Finder.
        XCTAssertTrue(MenuNavigation.activationLeavesMenu(.row(project), projectState: running))
        XCTAssertTrue(MenuNavigation.activationLeavesMenu(.row(project), projectState: .needsReapproval))
        XCTAssertTrue(MenuNavigation.activationLeavesMenu(.row(listener), projectState: nil))
        for action: RowAction in [.open, .logs, .review, .revealFolder, .addAsServer] {
            XCTAssertTrue(MenuNavigation.activationLeavesMenu(.action(project, action), projectState: running), "\(action)")
        }
        for focus: MenuFocus in [.addServer, .footerAdd, .settings] {
            XCTAssertTrue(MenuNavigation.activationLeavesMenu(focus, projectState: nil), "\(focus)")
        }
        // Stays open to show the result.
        XCTAssertFalse(MenuNavigation.activationLeavesMenu(.row(project), projectState: .stopped))
        for action: RowAction in [.start, .stop, .restart, .copyURL] {
            XCTAssertFalse(MenuNavigation.activationLeavesMenu(.action(project, action), projectState: running), "\(action)")
        }
        for focus: MenuFocus? in [nil, .filter, .showMore, .footerStopAll] {
            XCTAssertFalse(MenuNavigation.activationLeavesMenu(focus, projectState: nil))
        }
    }
}
