import XCTest
@testable import SessionKit

/// The friend's words on the screens after a file arrives (#3247 step 5): Cole's name leads, and no engineering term
/// reaches a friend.
final class FriendArrivalWordsTests: XCTestCase {
    func testTheSenderLeadsAndAnUnnamedFriendIsStillAFriend() {
        XCTAssertEqual(FriendArrivalWords.fromLine(senderLabel: "Cole"), "From Cole")
        XCTAssertEqual(FriendArrivalWords.fromLine(senderLabel: "  Cole "), "From Cole")
        XCTAssertEqual(FriendArrivalWords.fromLine(senderLabel: ""), "From a friend")
        XCTAssertEqual(FriendArrivalWords.fromLine(senderLabel: nil), "From a friend")
        XCTAssertEqual(FriendArrivalWords.fromLine(senderLabel: "   "), "From a friend")
    }

    func testOneTitleForOneOrManySenders() {
        XCTAssertEqual(FriendArrivalWords.sectionTitle(senderLabels: ["Cole"]), "From Cole")
        XCTAssertEqual(FriendArrivalWords.sectionTitle(senderLabels: ["Cole", "Cole"]), "From Cole")
        XCTAssertEqual(FriendArrivalWords.sectionTitle(senderLabels: ["Cole", "Ada"]), "From friends")
        XCTAssertEqual(FriendArrivalWords.sectionTitle(senderLabels: ["Cole", ""]), "From friends")
        XCTAssertEqual(FriendArrivalWords.sectionTitle(senderLabels: [""]), "From a friend")
        XCTAssertEqual(FriendArrivalWords.sectionTitle(senderLabels: []), "From a friend")
    }

    func testThePossessiveFallsBackToYourFriend() {
        XCTAssertEqual(FriendArrivalWords.possessiveMargins(senderLabel: "Cole"), "Cole's Margins")
        XCTAssertEqual(FriendArrivalWords.possessiveMargins(senderLabel: nil), "Your friend's Margins")
    }

    func testTheHonestNoteIsTheReviewedSentence() {
        XCTAssertEqual(FriendArrivalWords.aboutTitle, "About this file")
        XCTAssertEqual(FriendArrivalWords.aboutNote, "Unchanged since it was sent. The name on it comes from the sender's app and isn't proven.")
    }

    func testAPassingPlacementSaysNothingAndAProblemSaysOneLine() {
        XCTAssertNil(FriendArrivalWords.placementProblem(.resolved))
        XCTAssertEqual(FriendArrivalWords.placementProblem(.pending), "Matching positions in your episode")
        for status in [ImportedSourceResolutionStatus.contextOnly, .ambiguous, .wrongSource, .unavailable, .pending] {
            XCTAssertFalse(FriendArrivalWords.placementProblem(status)?.isEmpty ?? true, "\(status)")
        }
    }

    func testPlayModesUseTheReviewedAutoPlayWords() {
        XCTAssertEqual(FriendArrivalWords.playModeLabel(.guided), "Play as you reach them")
        XCTAssertEqual(FriendArrivalWords.playModeLabel(.companion), "A tone marks each one")
        XCTAssertEqual(Set(ImportedCommentaryRevealMode.allCases.map(FriendArrivalWords.playModeLabel)).count, 3,
                       "each mode reads differently")
    }

    func testTheSpokenLabelHasNoEngineeringTermAndNoPassingCheck() {
        let label = FriendArrivalWords.layerAccessibilityLabel(
            senderLabel: "Cole", isEnabled: true, isMuted: false, mode: .companion, placementProblem: nil)
        XCTAssertEqual(label, "From Cole. Cole's Margins are on. Not muted. When Margins play: A tone marks each one")
        let withProblem = FriendArrivalWords.layerAccessibilityLabel(
            senderLabel: "Cole", isEnabled: false, isMuted: true, mode: .guided, placementProblem: "Wrong source")
        XCTAssertTrue(withProblem.hasSuffix("Wrong source"))
        XCTAssertTrue(withProblem.contains("Cole's Margins are off"))
        for text in [label, withProblem] {
            for term in ["layer", "ntegrity", "cryptographically", "Reveal mode", "Source resolution"] {
                XCTAssertFalse(text.contains(term), term)
            }
        }
    }
}
