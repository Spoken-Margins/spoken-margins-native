import XCTest
@testable import SessionKit

final class TimelineEditingDockTests: XCTestCase {
    func testTheDockHidesWhileTheEditorHasFocus() {
        var dock = TimelineEditingDock()
        XCTAssertFalse(dock.hidesDock)
        dock.editorFocusChanged(true)
        dock.keyboardWillShow()
        XCTAssertTrue(dock.hidesDock)
        XCTAssertFalse(dock.waitsForKeyboard)
    }

    func testDoneKeepsTheDockAwayUntilTheKeyboardHasLeft() {
        // #4043: the dock came back while the keyboard was still sliding away, and the Import button ended up behind it.
        var dock = TimelineEditingDock()
        dock.editorFocusChanged(true)
        dock.keyboardWillShow()
        dock.editorFocusChanged(false)
        XCTAssertTrue(dock.hidesDock, "The dock must wait for the keyboard to finish leaving")
        XCTAssertTrue(dock.waitsForKeyboard)
        dock.keyboardDidHide()
        XCTAssertFalse(dock.hidesDock)
        XCTAssertFalse(dock.waitsForKeyboard)
    }

    func testWithNoKeyboardUpTheDockReturnsAtOnce() {
        // A hardware keyboard, or focus lost before the software keyboard arrived.
        var dock = TimelineEditingDock()
        dock.editorFocusChanged(true)
        dock.editorFocusChanged(false)
        XCTAssertFalse(dock.hidesDock)
    }

    func testRefocusingWhileTheKeyboardLeavesKeepsTheDockHidden() {
        var dock = TimelineEditingDock()
        dock.editorFocusChanged(true)
        dock.keyboardWillShow()
        dock.editorFocusChanged(false)
        dock.editorFocusChanged(true)
        dock.keyboardDidHide()
        XCTAssertTrue(dock.hidesDock, "The editor has focus again, so the dock stays out of the way")
        XCTAssertFalse(dock.waitsForKeyboard)
    }

    func testAKeyboardRaisedElsewhereNeverHidesTheDock() {
        // A sheet's text field over the playback screen raises the keyboard without the Timeline editor.
        var dock = TimelineEditingDock()
        dock.keyboardWillShow()
        XCTAssertFalse(dock.hidesDock)
        dock.keyboardDidHide()
        XCTAssertFalse(dock.hidesDock)
    }

    func testAMissedHideNeverStrandsTheDock() {
        var dock = TimelineEditingDock()
        dock.editorFocusChanged(true)
        dock.keyboardWillShow()
        dock.editorFocusChanged(false)
        dock.keyboardWaitTimedOut()
        XCTAssertFalse(dock.hidesDock)
        dock.keyboardDidHide()
        XCTAssertFalse(dock.hidesDock, "A late hide changes nothing")
    }
}
