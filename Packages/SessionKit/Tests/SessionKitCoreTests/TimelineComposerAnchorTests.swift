import XCTest
@testable import SessionKit

/// #4047: the rail snapped back to the Reflect box whenever the editor lost focus, even when the listener had
/// dragged up to read an earlier entry. Only a Done or Import from the box itself re-anchors it.
final class TimelineComposerAnchorTests: XCTestCase {
    func testDoneFromTheBoxScrollsItAboveTheReturningDockTwice() {
        var anchor = TimelineComposerAnchor()
        anchor.editorGainedFocus()
        anchor.editingEndedFromComposer()
        XCTAssertTrue(anchor.dockReturned())
        XCTAssertTrue(anchor.dockInsetGrew())
        XCTAssertFalse(anchor.dockInsetGrew(), "one more scroll per return, not one per inset change")
    }

    func testFocusLostWithoutDoneNeverScrolls() {
        // The listener dragged the rail down to read an earlier entry: the keyboard is pulled away, focus leaves.
        var anchor = TimelineComposerAnchor()
        anchor.editorGainedFocus()
        XCTAssertFalse(anchor.dockReturned())
        XCTAssertFalse(anchor.dockInsetGrew())
    }

    func testTheListenerScrollingAfterDoneKeepsTheirPlace() {
        var anchor = TimelineComposerAnchor()
        anchor.editingEndedFromComposer()
        anchor.listenerScrolled()
        XCTAssertFalse(anchor.dockReturned())
        XCTAssertFalse(anchor.dockInsetGrew())
    }

    func testTheListenerScrollingBetweenTheTwoScrollsCancelsTheSecond() {
        var anchor = TimelineComposerAnchor()
        anchor.editingEndedFromComposer()
        XCTAssertTrue(anchor.dockReturned())
        anchor.listenerScrolled()
        XCTAssertFalse(anchor.dockInsetGrew())
    }

    func testAnEditingEndedEarlierDoesNotCarryIntoTheNextFocus() {
        var anchor = TimelineComposerAnchor()
        anchor.editingEndedFromComposer()
        anchor.editorGainedFocus()
        XCTAssertFalse(anchor.dockReturned(), "the new editing began after the old one ended")
    }

    func testTheDockReturningTwiceScrollsOnlyForTheOneDone() {
        var anchor = TimelineComposerAnchor()
        anchor.editingEndedFromComposer()
        XCTAssertTrue(anchor.dockReturned())
        XCTAssertFalse(anchor.dockReturned())
    }
}
