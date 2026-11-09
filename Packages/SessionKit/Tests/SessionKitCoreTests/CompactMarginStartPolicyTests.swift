import XCTest
@testable import SessionKit

/// #2511: the compact start switches the session ahead only in the one case that is safe, and every neighbour keeps the old order.
final class CompactMarginStartPolicyTests: XCTestCase {
    private let ordinary = CompactMarginStartPolicy.Situation(
        appInForeground: true, marginVoiceInvolved: false, skimOrRecordingActive: false, recorderCanPrepare: true
    )

    func testAForegroundStartWithNothingElseGoingPreparesAhead() {
        XCTAssertTrue(CompactMarginStartPolicy.preparesSessionAhead(ordinary))
    }

    func testEveryNeighbouringSituationKeepsTheOldOrder() {
        var background = ordinary; background.appInForeground = false
        var voice = ordinary; voice.marginVoiceInvolved = true
        var skimOrRecording = ordinary; skimOrRecording.skimOrRecordingActive = true
        var noPreparer = ordinary; noPreparer.recorderCanPrepare = false
        for (name, situation) in [("background", background), ("margin voice", voice), ("skim or recording", skimOrRecording), ("no preparer", noPreparer)] {
            XCTAssertFalse(CompactMarginStartPolicy.preparesSessionAhead(situation), name)
        }
    }
}
