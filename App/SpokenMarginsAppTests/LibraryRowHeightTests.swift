import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #4062: a Library row tells the listener how far they are and whose Margins are on the item without growing taller.
///
/// The old row stacked, under a two-line title and its detail line, a label line for the item loaded now, a line for the
/// listener's own Margins and a line for a friend's. These tests lay out the production row and fail if a line comes
/// back. "Today's height" is rebuilt from the same row: the row with no Margins, plus the height each of the two old
/// Margins lines added on its own, so the bound moves with the fonts and needs no number recorded from `main`.
@MainActor
final class LibraryRowHeightTests: XCTestCase {
    private static let longTitle = "Hard cases for AI behavioural design and the long way round to a second line of title"

    private func row(
        id: String = "row", percent: Int? = nil, completed: Bool = false, own: Int = 0,
        shared: SharedMarginTally = .none, podcast: Bool = false
    ) -> LibraryItemRow {
        var row = LibraryItemRow(
            id: id, title: Self.longTitle, status: "Ready", canDelete: true, hasContinuationSession: percent != nil,
            continuationProgressPercent: percent, isCompleted: completed, mediaType: podcast ? "podcast" : "article",
            hasNativeAudio: podcast, sourceTitle: "forethought.org")
        row.marginCount = own
        row.sharedMargins = shared
        if podcast {
            row.mediaDurationMs = 3_600_000
            row.continuationMediaTimeMs = percent.map { 36_000 * $0 }
        } else {
            row.textCharacterCount = 35_000
        }
        return row
    }

    /// The row as the Library draws it, at the width of a standard iPhone.
    private func height(
        of row: LibraryItemRow, isCurrent: Bool = false, size: DynamicTypeSize = .large, width: CGFloat = 390
    ) -> CGFloat {
        let view = ExperienceLibraryCompactRow(
            row: row, isCurrentItem: isCurrent, isLoadedItem: isCurrent, playbackSpeed: 1, spokenNoteFolders: SpokenNoteFolderLedger(),
            onOpen: {}, onPlay: {}, onComplete: {}, onMarkUnfinished: {}, onMarkMarginsHeard: {}, onPrepareOffline: {}, onPlayNext: {},
            onAddToQueue: {}, onAddToCollection: {}, onDelete: {}
        )
        .environment(\.dynamicTypeSize, size)
        return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 4_000)).height
    }

    private let friends = SharedMarginTally(total: 3, new: 1)

    func testProgressAndTimeLeftAddNoHeight() {
        for podcast in [false, true] {
            let unstarted = height(of: row(podcast: podcast))
            let inProgress = height(of: row(percent: 43, podcast: podcast))
            XCTAssertEqual(inProgress, unstarted, accuracy: 0.5,
                           "podcast \(podcast): time left and the ring made the row \(inProgress - unstarted) pt taller")
            let done = height(of: row(completed: true, podcast: podcast))
            XCTAssertEqual(done, unstarted, accuracy: 0.5, "podcast \(podcast): a finished row is a different height")
        }
    }

    func testTheItemLoadedNowHasNoLabelLineAboveTheTitle() {
        for percent in [nil, 43] as [Int?] {
            let plain = height(of: row(percent: percent))
            let current = height(of: row(percent: percent), isCurrent: true)
            XCTAssertEqual(current, plain, accuracy: 0.5, "the item loaded now made the row \(current - plain) pt taller")
        }
    }

    func testOneMarginsLineIsNoTallerThanTheTwoItReplaces() {
        let none = height(of: row(percent: 43))
        let ownOnly = height(of: row(percent: 43, own: 2))
        let friendsOnly = height(of: row(percent: 43, shared: friends))
        let both = height(of: row(percent: 43, own: 2, shared: friends))
        XCTAssertGreaterThan(ownOnly, none, "precondition: own Margins draw a line")
        XCTAssertGreaterThan(friendsOnly, none, "precondition: a friend's Margins draw a line")
        let oldBoth = none + (ownOnly - none) + (friendsOnly - none)
        XCTAssertLessThanOrEqual(both, oldBoth + 0.5, "both kinds of Margins are taller than the two lines they replaced")
        // The loaded item has no label line above its title any more, so it is no taller than the old rows without one.
        let bothCurrent = height(of: row(percent: 43, own: 2, shared: friends), isCurrent: true)
        XCTAssertLessThanOrEqual(bothCurrent, oldBoth + 0.5, "the loaded item with both kinds of Margins grew")
    }

    func testAccessibilitySizesReflowWithoutCuttingTheRow() {
        let big = height(of: row(percent: 43, own: 12, shared: SharedMarginTally(total: 30, new: 12)), size: .accessibility3, width: 390)
        XCTAssertGreaterThan(big, 0)
        let small = height(of: row(percent: 43, own: 12, shared: SharedMarginTally(total: 30, new: 12)), size: .large, width: 390)
        XCTAssertGreaterThan(big, small, "an accessibility size makes the row taller, never clips it")
    }
}
