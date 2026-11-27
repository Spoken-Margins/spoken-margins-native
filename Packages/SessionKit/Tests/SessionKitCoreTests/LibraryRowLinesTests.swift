import Foundation
import XCTest
@testable import SessionKit

/// #4062, #4698: the Library row's length words and Margins tag, from the row alone.
final class LibraryRowLinesTests: XCTestCase {
    // 14 characters a second at 1x: 21 000 characters is 25 min.
    private func text(percent: Int? = nil, completed: Bool = false, characters: Int? = 21_000, marginCount: Int = 0,
                      shared: SharedMarginTally = .none) -> LibraryItemRow {
        var row = LibraryItemRow(id: "t", title: "T", status: "Ready", canDelete: true,
                                 hasContinuationSession: percent != nil, continuationProgressPercent: percent, isCompleted: completed)
        row.textCharacterCount = characters
        row.marginCount = marginCount
        row.sharedMargins = shared
        return row
    }

    private func audio(percent: Int? = nil, completed: Bool = false, durationMs: Int? = 2 * 3_600_000, placeMs: Int? = nil,
                       marginCount: Int = 0, shared: SharedMarginTally = .none) -> LibraryItemRow {
        var row = LibraryItemRow(id: "p", title: "P", status: "Ready", canDelete: true,
                                 hasContinuationSession: percent != nil, continuationProgressPercent: percent, isCompleted: completed,
                                 mediaType: "podcast", hasNativeAudio: true)
        row.mediaDurationMs = durationMs
        row.continuationMediaTimeMs = placeMs
        row.marginCount = marginCount
        row.sharedMargins = shared
        return row
    }

    private func lines(_ row: LibraryItemRow, speed: Double = 1, exported: Bool = false) -> LibraryRowLines {
        LibraryRowLines(row: row, playbackSpeed: speed, isExported: exported)
    }

    // MARK: Progress words

    func testTextInProgressSaysAboutHowMuchIsLeftAndFollowsTheSpeed() {
        // 52% of 21 000 characters heard leaves 10 080: 12 min at 1x, 6 min at 2x.
        XCTAssertEqual(lines(text(percent: 52)).progress, "12 min")
        XCTAssertEqual(lines(text(percent: 52), speed: 2).progress, "6 min")
        XCTAssertEqual(lines(text(percent: 52)).progressSpoken, "52 percent listened, about 12 minutes left")
        XCTAssertEqual(lines(text(percent: 99, characters: 21_000)).progress, "under 1 min")
        XCTAssertEqual(lines(text(percent: 99)).progressSpoken, "99 percent listened, less than a minute left")
    }

    func testAPodcastInProgressUsesItsFilesLengthMinusTheSavedPlace() {
        // 2 h episode, 1% in at 1:12 (72 s): 1 h 58 min 48 s left, which rounds to 1 h 59 min.
        let nearStart = lines(audio(percent: 1, placeMs: 72_000))
        XCTAssertEqual(nearStart.progress, "1 h 59 min")
        XCTAssertEqual(nearStart.progressSpoken, "1 percent listened, 1 hour 59 minutes left")
        // The percent is not used when the place is known: 43% on a 2 h file, but the place says 24 min left.
        XCTAssertEqual(lines(audio(percent: 43, placeMs: 2 * 3_600_000 - 24 * 60_000)).progress, "24 min")
        // Exactly an hour left is "1 h", not "1 h 0 min".
        XCTAssertEqual(lines(audio(percent: 50, placeMs: 3_600_000)).progress, "1 h")
        XCTAssertEqual(lines(audio(percent: 99, placeMs: 2 * 3_600_000 - 30_000)).progress, "under 1 min")
        XCTAssertEqual(lines(audio(percent: 99, placeMs: 2 * 3_600_000 - 30_000)).progressSpoken, "99 percent listened, less than a minute left")
        // A place past the end (a stale duration) is the end, never a negative.
        XCTAssertEqual(lines(audio(percent: 99, placeMs: 3 * 3_600_000)).progress, "under 1 min")
    }

    func testAnInProgressRowWithNothingToCountAgainstShowsThePercentAsToday() {
        XCTAssertEqual(lines(audio(percent: 43, durationMs: nil, placeMs: 1_000)).progress, "43%")
        XCTAssertEqual(lines(audio(percent: 43, durationMs: 3_600_000, placeMs: nil)).progress, "43%", "a place the row doesn't hold")
        XCTAssertEqual(lines(audio(percent: 43, durationMs: nil, placeMs: nil)).progressSpoken, "43 percent listened")
        XCTAssertEqual(lines(text(percent: 43, characters: nil)).progress, "43%")
        XCTAssertEqual(lines(text(percent: 43, characters: 0)).progress, "43%", "an empty text has no estimate")
    }

    func testANotStartedRowShowsItsLengthOrNothing() {
        XCTAssertEqual(lines(text()).progress, "25 min")
        XCTAssertEqual(lines(text()).progressSpoken, "about 25 minutes")
        XCTAssertEqual(lines(text(), speed: 2).progress, "13 min")
        XCTAssertEqual(lines(text(characters: 300)).progress, "under 1 min")
        XCTAssertEqual(lines(text(characters: 300)).progressSpoken, "less than a minute")
        XCTAssertEqual(lines(audio(durationMs: 41 * 60_000)).progress, "41 min")
        XCTAssertEqual(lines(audio(durationMs: 41 * 60_000)).progressSpoken, "41 minutes")
        XCTAssertEqual(lines(audio(durationMs: 5 * 3_600_000 / 4)).progressSpoken, "1 hour 15 minutes")
        XCTAssertEqual(lines(audio(durationMs: 20_000)).progress, "under 1 min")
        XCTAssertNil(lines(audio(durationMs: nil)).progress, "no length, no words")
        XCTAssertNil(lines(text(characters: nil)).progress)
    }

    func testATextRowNeverReadsAnAudioLengthAndALongTextReachesHours() {
        // A text item with rendered narration can carry a media length; its words stay the character estimate.
        var row = text(percent: 50, characters: 63_000) // 75 min total at 1x, 37.5 min left, rounds to 38
        row.mediaDurationMs = 10_000
        row.continuationMediaTimeMs = 9_000
        XCTAssertEqual(lines(row).progress, "38 min")
        var long = text(percent: 10, characters: 63_000) // 90% of 75 min is 67.5 min left, rounds to 68
        long.mediaDurationMs = 10_000
        XCTAssertEqual(lines(long).progress, "1 h 8 min")
        XCTAssertEqual(lines(long).progressSpoken, "10 percent listened, about 1 hour 8 minutes left")
    }

    func testASessionAtZeroPercentIsNotStarted() {
        XCTAssertEqual(lines(text(percent: 0)).progress, "25 min")
        XCTAssertNil(lines(text(percent: 0)).ringFraction)
        XCTAssertEqual(lines(audio(percent: 0, durationMs: 41 * 60_000, placeMs: 0)).progress, "41 min")
    }

    func testAFinishedRowShowsItsWholeLengthAndSaysCompletedOnlyToVoiceOver() {
        // #4698: "Completed" took the length's place on screen; the length stays and the check (or nothing) marks it.
        XCTAssertEqual(lines(text(percent: 99, completed: true)).progress, "25 min")
        XCTAssertEqual(lines(text(percent: 99, completed: true)).progressSpoken, "Completed, about 25 minutes")
        XCTAssertEqual(lines(audio(percent: 100, completed: true, placeMs: 5)).progress, "2 h", "the whole length, not what was left")
        XCTAssertEqual(lines(audio(percent: 100, completed: true, placeMs: 5)).progressSpoken, "Completed, 2 hours")
        XCTAssertEqual(lines(text(completed: true)).progress, "25 min", "marked complete with no session")
        XCTAssertEqual(lines(text(completed: true), exported: true).progress, "25 min · Exported")
        XCTAssertEqual(lines(text(completed: true), exported: true).progressSpoken, "Completed, exported, about 25 minutes")
        XCTAssertNil(lines(audio(completed: true, durationMs: nil)).progress, "no length and not exported: nothing on screen")
        XCTAssertEqual(lines(audio(completed: true, durationMs: nil)).progressSpoken, "Completed")
        XCTAssertEqual(lines(audio(completed: true, durationMs: nil), exported: true).progress, "Exported")
        XCTAssertNil(lines(text(percent: 99, completed: true)).ringFraction)
    }

    func testTheRingShowsOnlyForAnItemInProgress() {
        XCTAssertEqual(lines(text(percent: 43)).ringFraction, 0.43)
        XCTAssertEqual(lines(audio(percent: 100, placeMs: 1)).ringFraction, 1, "a session at 100% that isn't marked finished")
        XCTAssertNil(lines(text()).ringFraction)
        XCTAssertNil(lines(text(percent: 99, completed: true)).ringFraction)
        XCTAssertEqual(lines(text(percent: 250)).ringFraction, 1, "a bad percent never draws past the ring")
        XCTAssertNil(lines(text(percent: -5)).ringFraction)
    }

    // MARK: Margins tag (#4698)

    func testTheTagCountsEveryMarginOnTheItemOnce() {
        let shared = SharedMarginTally(total: 3, new: 1, senders: [.init(key: "c", name: "Cole", count: 3)])
        let both = lines(text(marginCount: 11, shared: shared))
        XCTAssertEqual(both.marginTag, "14")
        XCTAssertTrue(both.hasNewMargins)
        XCTAssertEqual(both.marginsSpoken, "14 Margins, 1 new from Cole")

        let own = lines(text(marginCount: 2))
        XCTAssertEqual(own.marginTag, "2")
        XCTAssertFalse(own.hasNewMargins)
        XCTAssertEqual(own.marginsSpoken, "2 Margins")
        XCTAssertEqual(lines(text(marginCount: 1)).marginsSpoken, "1 Margin")

        let friends = lines(text(shared: shared))
        XCTAssertEqual(friends.marginTag, "3")
        XCTAssertEqual(friends.marginsSpoken, "3 Margins, 1 new from Cole")

        let none = lines(text())
        XCTAssertNil(none.marginTag)
        XCTAssertFalse(none.hasNewMargins)
        XCTAssertNil(none.marginsSpoken)
    }

    func testTheTagStopsAtNinetyNinePlus() {
        XCTAssertEqual(lines(text(marginCount: 99)).marginTag, "99")
        XCTAssertEqual(lines(text(marginCount: 60, shared: SharedMarginTally(total: 40, new: 0))).marginTag, "99+")
        XCTAssertEqual(lines(text(marginCount: 60, shared: SharedMarginTally(total: 40, new: 0))).marginsSpoken, "100 Margins",
                       "VoiceOver says the real count")
    }

    func testTheNewOnesSayWhoTheyAreFrom() {
        XCTAssertEqual(lines(text(shared: SharedMarginTally(total: 2, new: 2))).marginsSpoken, "2 Margins, 2 new from a friend")
        let two = SharedMarginTally(total: 5, new: 2, senders: [.init(key: "c", name: "Cole", count: 3), .init(key: "s", name: "Sam", count: 2)])
        XCTAssertEqual(lines(text(shared: two)).marginsSpoken, "5 Margins, 2 new from friends")
    }

    /// A browser friend who typed no name arrives as one sender with an empty name (Test Desk run on #5397): VoiceOver
    /// said "1 new from " with nothing after it.
    func testASenderWithNoNameIsAFriend() {
        for blank in ["", "  ", "\n"] {
            let tally = SharedMarginTally(total: 1, new: 1, senders: [.init(key: "b", name: blank, count: 1)])
            XCTAssertEqual(lines(text(shared: tally)).marginsSpoken, "1 Margin, 1 new from a friend")
        }
        let padded = SharedMarginTally(total: 1, new: 1, senders: [.init(key: "s", name: " Sam ", count: 1)])
        XCTAssertEqual(lines(text(shared: padded)).marginsSpoken, "1 Margin, 1 new from Sam")
    }

    func testOnlyAFriendsUnheardMarginsLightTheDot() {
        let heard = lines(text(marginCount: 2, shared: SharedMarginTally(total: 3, new: 0, senders: [.init(key: "c", name: "Cole", count: 3)])))
        XCTAssertFalse(heard.hasNewMargins)
        XCTAssertEqual(heard.marginTag, "5")
        XCTAssertEqual(heard.marginsSpoken, "5 Margins")
        XCTAssertNil(lines(text(marginCount: -3)).marginTag, "a negative count is no count")
    }

    // MARK: The builder fills the two new fields from what it already holds

    func testTheBuilderCarriesTheMediaLengthAndTheSavedPlaceOfTheContinuationSession() throws {
        func item(_ id: String, durationMs: Int?) -> Item {
            Item(id: id, title: "Title \(id)", mediaType: "podcast", text: nil, externalReference: nil, status: "ready",
                 media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/\(id).mp3", durationMs: durationMs))
        }
        func session(_ id: String, itemId: String, mediaTimeMs: Int?, percent: Int, updatedAt: TimeInterval = 1) -> Session {
            Session(id: id, itemId: itemId, updatedAt: Date(timeIntervalSince1970: updatedAt), status: "in_progress", phase: .itemPlayback,
                    currentTargetType: .itemTextTTS, currentTargetId: itemId,
                    position: Position(charOffset: 1, mediaTimeMs: mediaTimeMs), completionPercent: percent, playbackRate: 1)
        }
        let snapshot = LibraryReadSnapshot(
            items: [item("mid", durationMs: 7_200_000), item("fresh", durationMs: 2_460_000), item("nolength", durationMs: nil),
                    item("zero", durationMs: 0)],
            sessions: [session("s1", itemId: "mid", mediaTimeMs: 3_000_000, percent: 41),
                       session("s2", itemId: "nolength", mediaTimeMs: 5_000, percent: 3)],
            manifests: [], jobs: [], downloads: [])
        let context = StartupAudioContext(hasAcceptedCurrentTerms: false, hasSupertonicVoice: false)
        let rows = Dictionary(uniqueKeysWithValues: LibraryRowBuilder.rows(from: snapshot, context: context).map { ($0.id, $0) })

        let mid = try XCTUnwrap(rows["mid"])
        XCTAssertEqual(mid.mediaDurationMs, 7_200_000)
        XCTAssertEqual(mid.continuationMediaTimeMs, 3_000_000)
        XCTAssertEqual(LibraryRowLines(row: mid).progress, "1 h 10 min", "7 200 s minus 3 000 s is 4 200 s")
        let fresh = try XCTUnwrap(rows["fresh"])
        XCTAssertEqual(fresh.mediaDurationMs, 2_460_000)
        XCTAssertNil(fresh.continuationMediaTimeMs)
        XCTAssertEqual(LibraryRowLines(row: fresh).progress, "41 min")
        XCTAssertNil(try XCTUnwrap(rows["nolength"]).mediaDurationMs)
        XCTAssertEqual(LibraryRowLines(row: try XCTUnwrap(rows["nolength"])).progress, "3%")
        XCTAssertNil(try XCTUnwrap(rows["zero"]).mediaDurationMs, "a zero length is no length")
    }

    func testAFinishedAndAddedAgainItemKeepsNoSavedPlace() throws {
        // #4183: an item finished and then added again reads as fresh, so the old session's place must not leak
        // into "time left".
        var item = Item(id: "again", title: "T", mediaType: "podcast", text: nil, externalReference: nil, status: "ready",
                        media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/a.mp3", durationMs: 3_600_000))
        item.addedAgainAt = Date(timeIntervalSince1970: 100)
        let finished = Session(
            id: "s", itemId: "again", updatedAt: Date(timeIntervalSince1970: 10), status: "finished", phase: .finished,
            currentTargetType: .itemTextTTS, currentTargetId: "again", position: Position(charOffset: 1, mediaTimeMs: 3_500_000),
            completionPercent: 100, playbackRate: 1)
        let rows = LibraryRowBuilder.rows(
            from: LibraryReadSnapshot(items: [item], sessions: [finished], manifests: [], jobs: [], downloads: []),
            context: StartupAudioContext(hasAcceptedCurrentTerms: false, hasSupertonicVoice: false))
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.continuationMediaTimeMs)
        XCTAssertEqual(LibraryRowLines(row: row).progress, "1 h")
    }
}
