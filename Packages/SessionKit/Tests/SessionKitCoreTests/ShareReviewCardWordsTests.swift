import XCTest
@testable import SessionKit

/// #3839: the card's words are plain, one set, and none of the engineering phrases the screen-tour critics flagged.
final class ShareReviewCardWordsTests: XCTestCase {
    private var all: [String] {
        [
            ShareReviewCardWords.friendGets, ShareReviewCardWords.captionAsRecorded, ShareReviewCardWords.captionWithoutUms,
            ShareReviewCardWords.captionWordsOnly, ShareReviewCardWords.listenAsRecorded, ShareReviewCardWords.listenWithoutUms,
            ShareReviewCardWords.stopListening, ShareReviewCardWords.listenError, ShareReviewCardWords.yourWords,
            ShareReviewCardWords.wordsEditorCaption, ShareReviewCardWords.showAllWords, ShareReviewCardWords.showLess,
            ShareReviewCardWords.whereItLands, ShareReviewCardWords.whereItLandsCaption, ShareReviewCardWords.wordsJustBefore,
            ShareReviewCardWords.wordsJustAfter, ShareReviewCardWords.privateNote, ShareReviewCardWords.more,
            ShareReviewCardWords.pinnedStepSheetTitle,
            ShareReviewCardWords.yourWordsChanged, ShareReviewCardWords.showWhatChanged, ShareReviewCardWords.editWords,
            ShareReviewCardWords.done, ShareReviewCardWords.moreForThisMargin, ShareReviewCardWords.voicePending,
            ShareReviewCardWords.pauseNote, ShareReviewCardWords.previewWaiting, ShareReviewCardWords.backToYourMargins,
            ShareReviewCardWords.staleSelection, ShareReviewCardWords.headerHint, ShareReviewCardWords.stopSharing,
            ShareReviewCardWords.shareAnyway, ShareReviewCardWords.notNow,
            ShareReviewCardWords.waiting(count: 1), ShareReviewCardWords.waiting(count: 2),
            ShareReviewCardWords.failureTitle(count: 1), ShareReviewCardWords.failureTitle(count: 2),
            ShareReviewCardWords.failureMessage(count: 1), ShareReviewCardWords.failureMessage(count: 2),
        ]
    }

    func testNoLineUsesAnEngineeringPhrase() {
        let retired = ["voice assets", "exact local", "word-level", "timing", "High-reliability", "evidence", "transcript", "export", "—"]
        for line in all {
            for word in retired {
                XCTAssertFalse(line.localizedCaseInsensitiveContains(word), "\(line) says \(word)")
            }
        }
    }

    func testEachVersionHasItsOwnCaptionThatSaysWhatTheFriendGets() {
        let captions = [
            ShareReviewCardWords.captionAsRecorded, ShareReviewCardWords.captionWithoutUms, ShareReviewCardWords.captionWordsOnly,
        ]
        XCTAssertEqual(Set(captions).count, 3)
        for caption in captions {
            XCTAssertTrue(caption.hasPrefix("Your friend "), caption)
            XCTAssertTrue(caption.hasSuffix("."), caption)
        }
    }

    func testTheListenButtonsNameTheVersionTheyPlayAndTheLongestIsWithoutUms() {
        XCTAssertEqual(ShareReviewCardWords.listenAsRecorded.lowercased().hasSuffix(ShareCleanupWords.asRecorded.lowercased()), true)
        XCTAssertEqual(ShareReviewCardWords.listenWithoutUms.lowercased().hasSuffix(ShareCleanupWords.withoutUms.lowercased()), true)
        XCTAssertGreaterThanOrEqual(ShareReviewCardWords.listenWithoutUms.count, ShareReviewCardWords.listenAsRecorded.count)
    }

    func testEveryLineIsAShortSentenceOrLabel() {
        for line in all { XCTAssertLessThanOrEqual(line.count, 110, line) }
    }

    /// #4647: the one-list sheet's words, pinned as the Design wrote them.
    func testTheListWordsAreTheDesignsWords() {
        XCTAssertEqual(ShareReviewCardWords.yourWordsChanged, "Your words, with changes")
        XCTAssertEqual(ShareReviewCardWords.showWhatChanged, "Show what changed")
        XCTAssertEqual(ShareReviewCardWords.editWords, "Edit words")
        XCTAssertEqual(ShareReviewCardWords.moreForThisMargin, "More for this Margin")
        XCTAssertEqual(ShareReviewCardWords.voicePending, "Getting your voice without ums ready.")
        XCTAssertEqual(ShareReviewCardWords.pauseNote, "Pauses are shortened in your voice only. Listen to hear it as your friend will.")
        XCTAssertEqual(ShareReviewCardWords.previewWaiting, "Ready when your voices without ums are.")
        XCTAssertEqual(ShareReviewCardWords.backToYourMargins, "Back to your Margins")
        XCTAssertEqual(ShareReviewCardWords.staleSelection, "Your selection changed. Check it and share again.")
        XCTAssertEqual(ShareReviewCardWords.barCount(included: 3, total: 5), "3 of 5 selected")
    }

    func testTheHeaderSaysPositionStarAndVersionOnlyWhenTheyApply() {
        XCTAssertEqual(ShareReviewCardWords.headerLabel(position: 2, shown: 5, isStarred: true, version: ShareCleanupWords.withoutUms),
                       "Margin 2 of 5, starred, without ums")
        XCTAssertEqual(ShareReviewCardWords.headerLabel(position: 1, shown: 1, isStarred: false, version: ShareCleanupWords.asRecorded),
                       "Margin 1 of 1, as recorded")
        XCTAssertEqual(ShareReviewCardWords.headerLabel(position: 3, shown: 4, isStarred: false, version: nil), "Margin 3 of 4")
        XCTAssertEqual(ShareReviewCardWords.headerValue(isIncluded: true), "Included")
        XCTAssertEqual(ShareReviewCardWords.headerValue(isIncluded: false), "Not included")
        XCTAssertEqual(ShareReviewCardWords.headerHint, "Double-tap to include or leave out.")
    }

    func testTheWaitAndItsFailureSaySingularAndPlural() {
        XCTAssertEqual(ShareReviewCardWords.waiting(count: 1), "Getting 1 Margin ready…")
        XCTAssertEqual(ShareReviewCardWords.waiting(count: 2), "Getting 2 Margins ready…")
        XCTAssertEqual(ShareReviewCardWords.stopSharing, "Stop sharing")
        XCTAssertEqual(ShareReviewCardWords.failureTitle(count: 1), "Couldn't remove the ums from 1 Margin")
        XCTAssertEqual(ShareReviewCardWords.failureTitle(count: 2), "Couldn't remove the ums from 2 Margins")
        XCTAssertEqual(ShareReviewCardWords.failureMessage(count: 1),
                       "It can go without that change. Its card says how. Your recording on this iPhone stays as it is.")
        XCTAssertEqual(ShareReviewCardWords.failureMessage(count: 2),
                       "They can go without that change. Their cards say how. Your recording on this iPhone stays as it is.")
        XCTAssertEqual(ShareReviewCardWords.shareAnyway, "Share anyway")
        XCTAssertEqual(ShareReviewCardWords.notNow, "Not now")
    }

    func testTheCleanupSwitchAndAlertNoLongerPointToAStepThatIsGone() {
        XCTAssertEqual(ShareCleanupWords.switchCaption(isOn: false),
                       "Off. Your Margins go as you recorded them. You can still do this for one Margin below.")
        XCTAssertTrue(ShareCleanupWords.alertMessage.hasSuffix(
            "To stop this later, turn off Remove ums and long pauses at the top of this screen."))
        XCTAssertFalse(ShareCleanupWords.alertMessage.contains("Back to selection"))
    }
}
