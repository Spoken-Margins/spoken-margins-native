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

    func testAHiddenSenderIsNamedOrSaidToHaveNoName() {
        XCTAssertEqual(FriendArrivalWords.hiddenSenderName("  Ada "), "Ada")
        XCTAssertEqual(FriendArrivalWords.hiddenSenderName(nil), "A sender who gave no name")
        XCTAssertEqual(FriendArrivalWords.hiddenSenderName("   "), "A sender who gave no name")
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

    func testAPassingPlacementSaysNothingAndAProblemSaysOneLine() throws {
        XCTAssertNil(FriendArrivalWords.placementProblem(.resolved))
        XCTAssertEqual(FriendArrivalWords.placementProblem(.pending), "Matching positions in your episode")
        for status in [ImportedSourceResolutionStatus.contextOnly, .ambiguous, .wrongSource, .unavailable, .pending] {
            let line = try XCTUnwrap(FriendArrivalWords.placementProblem(status), "\(status)")
            XCTAssertTrue(line.split(separator: " ").count >= 5 && line.hasSuffix(".") || status == .pending,
                          "a problem is one plain sentence, not a one-word label: \(line)")
            XCTAssertFalse(line.lowercased().contains("source"), "\"source\" never reaches a friend: \(line)")
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
            senderLabel: "Cole", isEnabled: false, isMuted: true, mode: .guided, placementProblem: "These Margins can't be placed in your copy right now.")
        XCTAssertTrue(withProblem.hasSuffix("right now."))
        XCTAssertTrue(withProblem.contains("Cole's Margins are off"))
        for text in [label, withProblem] {
            for term in ["layer", "ntegrity", "cryptographically", "Reveal mode", "Source resolution"] {
                XCTAssertFalse(text.contains(term), term)
            }
        }
    }

    // MARK: a stand-in is never a name (#3247)

    private func layer(label: String?) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: "layer", itemId: "item", packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: label, importedAt: Date(timeIntervalSince1970: 0), sourceResolutionStatus: .resolved)
    }

    private let nobody: [String?] = [
        nil, "", " ", "\n\t ", "\u{00A0}",
        "Unsigned sender", " Unsigned sender ", "unsigned sender", "UNSIGNED SENDER", "Unsigned   sender",
        "Unsigned\u{00A0}sender", "Unsigned sender\n",
        "Imported collection", "imported collection", " Imported Collection\t", "Imported  collection"
    ]

    func testAFileThatNamesNobodyReadsAsAFriendThroughEveryRealLabelBuilder() {
        for raw in nobody {
            let snapshotLabel = SharedPacketArrival.snapshotSenderLabel(raw)
            let layerLabel = SharedMarginReview.senderLabel(of: layer(label: raw))
            let promptLabel = ImportedCommentaryPrompt(
                layer: layer(label: raw),
                interjection: ImportedCommentaryInterjection(
                    id: "i", layerId: "layer", packageScopedId: "p", createdAt: Date(timeIntervalSince1970: 0),
                    anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
                    resolution: ImportedAnchorResolution(evidenceClass: .exactEdition)),
                index: 1, count: 1).senderLabel
            for label in [snapshotLabel, layerLabel, promptLabel] {
                XCTAssertNil(SharedPacketArrival.senderName(label), "\(String(describing: raw)) -> \(label)")
                XCTAssertEqual(FriendArrivalWords.fromLine(senderLabel: label), "From a friend", "\(label)")
                XCTAssertEqual(FriendArrivalWords.possessiveMargins(senderLabel: label), "Your friend's Margins", "\(label)")
                XCTAssertEqual(FriendArrivalWords.sectionTitle(senderLabels: [label]), "From a friend", "\(label)")
                XCTAssertFalse(FriendArrivalWords.layerAccessibilityLabel(
                    senderLabel: label, isEnabled: true, isMuted: false, mode: .guided, placementProblem: nil)
                    .contains("Unsigned"), "\(label)")
            }
        }
    }

    func testARealNameSurvivesAndIsTrimmed() {
        for (raw, name) in [("Cole", "Cole"), ("  Cole\n", "Cole"), ("Zoë — 朋友", "Zoë — 朋友"),
                            ("Unsigned sender's friend", "Unsigned sender's friend"), ("Imported", "Imported"),
                            ("Ana Collection", "Ana Collection")] {
            XCTAssertEqual(SharedPacketArrival.senderName(SharedPacketArrival.snapshotSenderLabel(raw)), name, raw)
            XCTAssertEqual(FriendArrivalWords.fromLine(senderLabel: raw), "From \(name)", raw)
        }
        XCTAssertEqual(FriendArrivalWords.sectionTitle(senderLabels: ["Cole", "Unsigned sender"]), "From friends")
        XCTAssertEqual(FriendArrivalWords.sectionTitle(senderLabels: ["Cole", " Cole\n"]), "From Cole")
    }
}
