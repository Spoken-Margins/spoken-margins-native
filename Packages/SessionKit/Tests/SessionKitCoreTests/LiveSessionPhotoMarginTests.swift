import XCTest
@testable import SessionKit

/// #2708 PR 2: the words and the tap rules of a photo Margin. A line and its button come from the same place, so a
/// table over every kind and every camera state is enough to say they agree.
final class LiveSessionPhotoMarginTests: XCTestCase {
    func testPhotoIsOfferedOnPaperBooksAndSomethingElseOnly() {
        XCTAssertEqual(ElsewhereKind.allCases.filter(LiveSessionPhotoMargin.offers), [.paper, .other])
    }

    func testEveryKindThatOffersPhotoHasAHintAndNoOtherKindDoes() {
        for kind in ElsewhereKind.allCases {
            XCTAssertEqual(LiveSessionPhotoMargin.hint(for: kind) != nil, LiveSessionPhotoMargin.offers(kind), "\(kind)")
        }
        XCTAssertEqual(LiveSessionPhotoMargin.hint(for: .other), "Say what this is about.")
        XCTAssertTrue(try XCTUnwrap(LiveSessionPhotoMargin.hint(for: .paper)).contains("chapter 5"))
    }

    func testATapIsNeverDead() {
        let table: [(hasCamera: Bool, auth: LiveSessionPhotoMargin.CameraAuthorization, expected: LiveSessionPhotoMargin.Tap)] = [
            (true, .notDetermined, .openCamera), // iOS asks its own question; nothing of ours first
            (true, .authorized, .openCamera),
            (true, .denied, .cameraOff),
            (true, .restricted, .cameraOff),
            (false, .notDetermined, .noCamera),
            (false, .authorized, .noCamera),
            (false, .denied, .noCamera),
            (false, .restricted, .noCamera)
        ]
        for row in table {
            XCTAssertEqual(LiveSessionPhotoMargin.tap(hasCamera: row.hasCamera, authorization: row.auth), row.expected, "\(row)")
        }
    }

    func testPhotoIsLiveOnlyWhenNothingElseIsGoingOn() {
        XCTAssertTrue(LiveSessionPhotoMargin.isEnabled(isRunning: true, isRecording: false, isCapturingPhoto: false, hasPhotoWaiting: false))
        XCTAssertFalse(LiveSessionPhotoMargin.isEnabled(isRunning: false, isRecording: false, isCapturingPhoto: false, hasPhotoWaiting: false), "ended")
        XCTAssertFalse(LiveSessionPhotoMargin.isEnabled(isRunning: true, isRecording: true, isCapturingPhoto: false, hasPhotoWaiting: false), "recording")
        XCTAssertFalse(LiveSessionPhotoMargin.isEnabled(isRunning: true, isRecording: false, isCapturingPhoto: true, hasPhotoWaiting: false), "a second tap during the camera")
        XCTAssertFalse(LiveSessionPhotoMargin.isEnabled(isRunning: true, isRecording: false, isCapturingPhoto: false, hasPhotoWaiting: true), "a photo waiting for its words")
    }

    func testTheWordsNeverSayItemReviewOrPhone() {
        let lines = [
            LiveSessionPhotoMargin.couldNotKeepLine, LiveSessionPhotoMargin.noCameraLine, LiveSessionPhotoMargin.cameraOffLine,
            LiveSessionPhotoMargin.missingFileLine, LiveSessionPhotoMargin.writeInsteadLine, LiveSessionPhotoMargin.buttonAccessibilityLabel,
            LiveSessionPhotoMargin.openSettingsTitle, LiveSessionPhotoMargin.withoutPhotoTitle,
            LiveSessionPhotoMargin.rowAccessibilityValue, LiveSessionPhotoMargin.couldNotUseLine
        ] + ElsewhereKind.allCases.compactMap(LiveSessionPhotoMargin.hint)
        for line in lines {
            let lower = line.lowercased()
            XCTAssertFalse(lower.contains(" item"), line)
            XCTAssertFalse(lower.contains("review"), line)
            // The whole word: "microphone" is fine.
            XCTAssertNil(lower.range(of: #"\bphone\b"#, options: .regularExpression), "the app runs on iPad too: \(line)")
        }
    }
}
