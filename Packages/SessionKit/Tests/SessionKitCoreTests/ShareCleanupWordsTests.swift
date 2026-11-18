import XCTest
@testable import SessionKit

/// The share review's cleanup words (#3853). Each row pins words the Design chose, so a reword is a deliberate edit.
final class ShareCleanupWordsTests: XCTestCase {
    func testTheSwitchNamesWhatItRemovesAndItsCaptionsSayWhatHappens() {
        XCTAssertEqual(ShareCleanupWords.switchLabel, "Remove ums and long pauses")
        XCTAssertEqual(ShareCleanupWords.switchCaption(isOn: false),
            "Off. Your Margins go as you recorded them. You can still do this for one Margin in the next step.")
        let on = ShareCleanupWords.switchCaption(isOn: true)
        XCTAssertTrue(on.hasPrefix("On for this share and later ones."))
        XCTAssertTrue(on.contains("Turn it off to put them all back."))
    }

    func testTheBulkLineForOneFiveAndPartialFailures() {
        XCTAssertEqual(ShareCleanupWords.bulkResult(completed: 1, failed: 0), "Removed ums and pauses from 1 Margin")
        XCTAssertEqual(ShareCleanupWords.bulkResult(completed: 5, failed: 0), "Removed ums and pauses from 5 Margins")
        XCTAssertEqual(ShareCleanupWords.bulkResult(completed: 5, failed: 2),
            "Removed ums and pauses from 3 Margins. 2 couldn't be changed and go as they are.")
        XCTAssertEqual(ShareCleanupWords.bulkResult(completed: 5, failed: 1),
            "Removed ums and pauses from 4 Margins. 1 couldn't be changed and goes as it is.")
        XCTAssertEqual(ShareCleanupWords.bulkResult(completed: 2, failed: 2),
            "Couldn't remove ums and pauses from any of the 2 Margins. They go as they are.")
        XCTAssertEqual(ShareCleanupWords.bulkResult(completed: 1, failed: 1),
            "Couldn't remove ums and pauses from this Margin. It goes as it is.")
        XCTAssertEqual(ShareCleanupWords.running(completed: 2, total: 5), "Removing ums and pauses: 2 of 5")
    }

    func testTheCardSaysNothingWhenThereIsNothingTheSenderCanDo() {
        XCTAssertNil(ShareCleanupWords.cardLine(.cannotClean))
        XCTAssertNil(ShareCleanupWords.cardLine(.canClean))
        XCTAssertEqual(ShareCleanupWords.cardLine(.cleaning), "Removing ums and pauses…")
        XCTAssertEqual(ShareCleanupWords.cardLine(.cleaned), "Ums and long pauses removed. Tap a word or pause below to put it back.")
        XCTAssertFalse((ShareCleanupWords.cardLine(.cannotClean) ?? "").contains("word-level timing"))
    }

    func testTheChangeSummaryShowsOnlyThePartsThatAreNotZero() {
        XCTAssertEqual(ShareCleanupWords.changeSummary(wordsRemoved: 3, pausesShortened: 2), "3 words removed, 2 pauses shortened")
        XCTAssertEqual(ShareCleanupWords.changeSummary(wordsRemoved: 1, pausesShortened: 1), "1 word removed, 1 pause shortened")
        XCTAssertEqual(ShareCleanupWords.changeSummary(wordsRemoved: 1, pausesShortened: 0), "1 word removed")
        XCTAssertEqual(ShareCleanupWords.changeSummary(wordsRemoved: 0, pausesShortened: 4), "4 pauses shortened")
        XCTAssertNil(ShareCleanupWords.changeSummary(wordsRemoved: 0, pausesShortened: 0))
    }

    func testNoFailureLineShowsATechnicalReasonOrTheOldEngineeringWords() {
        let failures: [ShareCleanupWords.Failure] = [.pauseAnalysisUnavailable, .voiceNotPrepared, .recordingMissing, .previewNotPrepared, .regenerationFailed]
        for failure in failures {
            let text = failure.message
            XCTAssertFalse(text.contains("("), text)
            for retired in ["Cleaned voice", "Cleaned audio", "cleaned audio", "analysis", "Original voice", "word-level", "reviewable"] {
                XCTAssertFalse(text.contains(retired), "\(text) still says \(retired)")
            }
        }
        XCTAssertEqual(ShareCleanupWords.Failure.recordingMissing.message, "This Margin's recording is missing, so only its words can go.")
    }

    func testTheVersionNamesSayWhatTheFriendReceives() {
        XCTAssertEqual([ShareCleanupWords.asRecorded, ShareCleanupWords.withoutUms, ShareCleanupWords.wordsOnly],
                       ["As recorded", "Without ums", "Words only"])
    }

    func testTheAlertIsTheFirstTimeQuestion() {
        XCTAssertEqual(ShareCleanupWords.alertTitle, "Remove ums and long pauses?")
        XCTAssertEqual(ShareCleanupWords.alertAccept, "Remove them")
        XCTAssertEqual(ShareCleanupWords.alertDecline, "Not now")
        XCTAssertTrue(ShareCleanupWords.alertMessage.contains("Your recording on this iPhone stays as it is."))
        XCTAssertTrue(ShareCleanupWords.alertMessage.contains("Back to selection"))
    }
}
