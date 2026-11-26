import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #4062, #4698: a Library row tells the listener how long the item is and whose Margins are on it without growing taller.
///
/// A row is a title of at most two lines and one info line. The Margins are a tag on the artwork and a dot on its
/// corner, the item playing is a pause button in the ring, and a finished row keeps its length, so none of them may
/// add height. These tests lay out the production row and fail if a line comes back.
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
        of row: LibraryItemRow, isCurrent: Bool = false, showsCheck: Bool = false, size: DynamicTypeSize = .large, width: CGFloat = 390
    ) -> CGFloat {
        let view = ExperienceLibraryCompactRow(
            row: row, isLoadedItem: isCurrent, isPlayingNow: isCurrent, showsFinishedCheck: showsCheck, playbackSpeed: 1, spokenNoteFolders: SpokenNoteFolderLedger(),
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

    func testMarginsAddNoHeight() {
        let none = height(of: row(percent: 43))
        for (own, shared) in [(2, SharedMarginTally.none), (0, friends), (11, friends), (80, SharedMarginTally(total: 40, new: 3))] {
            let marked = height(of: row(percent: 43, own: own, shared: shared))
            XCTAssertEqual(marked, none, accuracy: 0.5, "\(own) own and \(shared.total) friends' Margins made the row \(marked - none) pt taller")
        }
        let playing = height(of: row(percent: 43, own: 11, shared: friends), isCurrent: true)
        XCTAssertEqual(playing, none, accuracy: 0.5, "the playing item with Margins grew")
    }

    func testTheFinishedCheckAddsNoHeight() {
        let plain = height(of: row(completed: true))
        let checked = height(of: row(completed: true, own: 3), showsCheck: true)
        XCTAssertEqual(checked, plain, accuracy: 0.5, "the check and the tag made a finished row taller")
    }

    func testAccessibilitySizesReflowWithoutCuttingTheRow() {
        let big = height(of: row(percent: 43, own: 12, shared: SharedMarginTally(total: 30, new: 12)), size: .accessibility3, width: 390)
        XCTAssertGreaterThan(big, 0)
        let small = height(of: row(percent: 43, own: 12, shared: SharedMarginTally(total: 30, new: 12)), size: .large, width: 390)
        XCTAssertGreaterThan(big, small, "an accessibility size makes the row taller, never clips it")
    }
}
