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

    func testAPassingPlacementSaysNothingAndOnlyADifferentEpisodeSaysOneLine() throws {
        XCTAssertNil(FriendArrivalWords.placementProblem(.resolved))
        for status in [ImportedSourceResolutionStatus.pending, .contextOnly, .ambiguous, .unavailable] {
            XCTAssertNil(FriendArrivalWords.placementProblem(status), "\(status): each Margin's own row says where it plays (#3789)")
        }
        let line = try XCTUnwrap(FriendArrivalWords.placementProblem(.wrongSource))
        XCTAssertTrue(line.hasSuffix("."), "one plain sentence: \(line)")
        XCTAssertFalse(line.lowercased().contains("source"), "\"source\" never reaches a friend: \(line)")
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

    // MARK: each fact once above Play (#3855)

    func testASingleLayerCardHidesItsSenderLineOnlyWhileTheIntroShows() {
        let table: [(introShowing: Bool, layers: Int, hides: Bool)] = [
            (true, 1, true),    // the intro names the sender; the one card need not
            (true, 2, false),   // two senders (or two packets): each card's name tells them apart
            (true, 3, false),
            (true, 0, false),   // no card, nothing to hide
            (false, 1, false),  // intro gone (all heard): the card says "From Sam" again
            (false, 2, false),
            (false, 0, false)
        ]
        for row in table {
            XCTAssertEqual(
                FriendArrivalWords.hidesLayerSenderLine(introShowing: row.introShowing, layerCount: row.layers), row.hides,
                "intro \(row.introShowing), \(row.layers) layers")
        }
    }

    func testTheSpokenLabelDropsOnlyTheLeadingFromSentenceWhenTheLineIsHidden() {
        let args = (isEnabled: true, isMuted: false, mode: ImportedCommentaryRevealMode.companion)
        let full = FriendArrivalWords.layerAccessibilityLabel(
            senderLabel: "Cole", isEnabled: args.isEnabled, isMuted: args.isMuted, mode: args.mode, placementProblem: nil)
        let hidden = FriendArrivalWords.layerAccessibilityLabel(
            senderLabel: "Cole", isEnabled: args.isEnabled, isMuted: args.isMuted, mode: args.mode, placementProblem: nil,
            includesSender: false)
        XCTAssertEqual(full, "From Cole. Cole's Margins are on. Not muted. When Margins play: A tone marks each one")
        XCTAssertEqual(hidden, "Cole's Margins are on. Not muted. When Margins play: A tone marks each one")
        XCTAssertFalse(hidden.hasPrefix("From "), "the sender sentence is said once, by the intro")
        // A placement problem and an unnamed sender still read the same way.
        let problem = FriendArrivalWords.layerAccessibilityLabel(
            senderLabel: "", isEnabled: false, isMuted: true, mode: .guided, placementProblem: "Not the same episode.",
            includesSender: false)
        XCTAssertEqual(problem, "Your friend's Margins are off. Muted. When Margins play: Play as you reach them. Not the same episode.")
    }

    func testATitleLeadsTheHiddenSenderLabelWithoutADoubledFullStop() {
        func label(_ title: String?) -> String {
            FriendArrivalWords.layerAccessibilityLabel(
                senderLabel: "Cole", isEnabled: true, isMuted: false, mode: .guided, placementProblem: nil,
                includesSender: false, leadingTitle: title)
        }
        let rest = "Cole's Margins are on. Not muted. When Margins play: Play as you reach them"
        let table: [(title: String?, expected: String)] = [
            ("Episode 4", "Episode 4. \(rest)"),
            ("Why?", "Why? \(rest)"),
            ("Stop!", "Stop! \(rest)"),
            ("Ends with a stop.", "Ends with a stop. \(rest)"),
            ("  Padded  ", "Padded. \(rest)"),
            ("", rest),
            ("   ", rest),
            (nil, rest)
        ]
        for row in table { XCTAssertEqual(label(row.title), row.expected, row.title ?? "nil") }
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

    /// The Lock Screen and Live Activity read the prompt's stored label, which is the stand-in for a nameless file.
    func testTheLockScreenAndLiveActivityNeverCarryTheStandIn() {
        XCTAssertEqual(FriendArrivalWords.nowPlayingArtist(senderLabel: " Cole "), "Cole")
        XCTAssertEqual(FriendArrivalWords.liveActivitySender(senderLabel: "Cole"), "Cole")
        for raw in [nil, "", "  ", SharedPacketArrival.snapshotSenderLabel(nil), "UNSIGNED  sender", "Imported collection"] {
            XCTAssertEqual(FriendArrivalWords.nowPlayingArtist(senderLabel: raw), "A friend", "\(raw ?? "nil")")
            XCTAssertEqual(FriendArrivalWords.liveActivitySender(senderLabel: raw), "a friend", "\(raw ?? "nil")")
        }
    }

    /// #3790: the Now screen's switch uses the owner-reviewed words, and its caption follows the global switch only.
    func testTheNowSwitchSaysWhatItDoesInTheReviewedWords() {
        XCTAssertEqual(FriendArrivalWords.autoPlayLabel, "Play Margins from friends as you reach them")
        XCTAssertEqual(FriendArrivalWords.autoPlayCaption(isOn: true), "The episode pauses for each one, then goes on.")
        XCTAssertEqual(FriendArrivalWords.autoPlayCaption(isOn: false), "A tone marks each one.")
        for isOn in [true, false] {
            let caption = FriendArrivalWords.autoPlayCaption(isOn: isOn)
            XCTAssertFalse(caption.contains("Auto-play"), "the old name is gone")
            XCTAssertFalse(caption.lowercased().contains("shared"), "a friend's Margin is never 'shared' on Now")
        }
    }
}
