import SwiftUI
import XCTest
@testable import SpokenMarginsApp

/// #221 lane: at 2.00× the player's "Sleep" label wrapped mid-word ("Sle" / "ep"), because the
/// rate, Sleep and More row was offered less width than it needed.
@MainActor
final class PlaybackControlsLayoutTests: XCTestCase {
    func testRateSleepAndMoreStayOnOneLineWhenTheRowIsOfferedLittleWidth() throws {
        let ideal = try renderedSize(proposedWidth: nil)
        let narrow = try renderedSize(proposedWidth: 120)
        XCTAssertEqual(narrow.height, ideal.height, accuracy: 1, "no label wraps onto a second line")
        XCTAssertEqual(narrow.width, ideal.width, accuracy: 1, "no label is truncated")
    }

    private func renderedSize(proposedWidth: CGFloat?) throws -> CGSize {
        let row = PlaybackSecondaryControlsRow {
            Text("2.00×")
            Label("Sleep", systemImage: "moon.zzz")
            Label("More", systemImage: "ellipsis")
        }
        let renderer = ImageRenderer(content: row)
        renderer.proposedSize = ProposedViewSize(width: proposedWidth, height: nil)
        return try XCTUnwrap(renderer.uiImage?.size)
    }
}
