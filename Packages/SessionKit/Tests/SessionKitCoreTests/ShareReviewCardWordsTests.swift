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
}
