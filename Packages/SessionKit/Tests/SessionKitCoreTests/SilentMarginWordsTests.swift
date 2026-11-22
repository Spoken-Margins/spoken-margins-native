import XCTest
@testable import SessionKit

/// #4934: when a row's button says "Go to this moment" instead of "Play this moment", and the words it uses.
final class SilentMarginWordsTests: XCTestCase {
    private func friend(
        _ words: String = "A thought.", senderReadAloud: Bool? = nil, listenerReadAloud: Bool? = nil, audioPath: String? = nil,
        senderMs: Int? = 9_000, _ resolution: ImportedAnchorResolution = .init(evidenceClass: .exactEdition, localMediaTimeMs: 9_000)
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: "imported-1", layerId: "layer-1", packageScopedId: "pkg::ij-003",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: senderMs == nil ? .text : .media, mediaTimeMs: senderMs),
            approvedTranscript: words, audioPath: audioPath, resolution: resolution,
            senderReadAloud: senderReadAloud, listenerReadAloud: listenerReadAloud)
    }

    private func layer(label: String? = "Sam", enabled: Bool = true) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: "layer-1", itemId: "item-1", packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "An episode"), displayLabel: label,
            importedAt: Date(timeIntervalSince1970: 1_790_000_000), isEnabled: enabled)
    }

    private func own(
        captureKind: InterjectionCaptureKind? = .written, targetType: InterjectionTargetType = .item, status: String = "active"
    ) -> Interjection {
        Interjection(
            id: "own", itemId: "item-1", sessionId: "session", targetType: targetType, targetId: "item-1",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), roughPercent: 25,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 80_000),
            audioPath: nil, audioStatus: "saved", transcriptionStatus: "complete", transcript: "Own note", cleanedTranscript: nil,
            displayText: nil, status: status, captureKind: captureKind)
    }

    func testAFriendsRowGoesToItOnlyWhenItIsNeverReadAloudAndHasAPlace() {
        defer { WrittenMarginSpeech.useVoiceCheck(nil) }
        WrittenMarginSpeech.useVoiceCheck(nil)
        let rows: [(String, ImportedCommentaryInterjection, Bool)] = [
            ("read aloud", friend(), false),
            ("a recording", friend(audioPath: "margin.m4a"), false),
            ("a recording that is gone: not silent, Play says so", friend(audioPath: "gone.m4a"), false),
            ("reading off by the sender", friend(senderReadAloud: false), true),
            ("reading off by the listener", friend(listenerReadAloud: false), true),
            ("sender off, listener back on", friend(senderReadAloud: false, listenerReadAloud: true), false),
            ("emoji only", friend("😀🎉"), true),
            ("placeholder words", friend("Voice Margin at 12:34"), true),
            ("silent, and no place", friend(senderReadAloud: false, senderMs: nil, .init(evidenceClass: .unresolved)), false),
            ("silent, at a passage of text", friend(senderReadAloud: false, senderMs: nil,
                .init(evidenceClass: .articleTextVerified, localStartChar: 300)), true),
        ]
        for (name, margin, expected) in rows {
            XCTAssertEqual(SilentMarginWords.friendGoesTo(margin, in: layer()), expected, name)
        }
    }

    func testAPassageFollowsItsLayerAsGoToDoes() {
        let passage = friend(senderReadAloud: false, senderMs: nil, .init(evidenceClass: .articleTextVerified, localStartChar: 300))
        XCTAssertTrue(SilentMarginWords.friendGoesTo(passage, in: layer()))
        XCTAssertFalse(SilentMarginWords.friendGoesTo(passage, in: layer(enabled: false)), "a layer turned off has nowhere to go")
    }

    func testOnlyAnActiveWrittenMarginOnTheItemWithAPlaceIsOwnWrittenGoTo() {
        XCTAssertTrue(SilentMarginWords.ownWrittenGoesTo(own()))
        XCTAssertFalse(SilentMarginWords.ownWrittenGoesTo(own(captureKind: nil)), "a spoken Margin keeps Play")
        XCTAssertFalse(SilentMarginWords.ownWrittenGoesTo(own(captureKind: .audio)))
        XCTAssertFalse(SilentMarginWords.ownWrittenGoesTo(own(targetType: .assistantTurn)))
        XCTAssertFalse(SilentMarginWords.ownWrittenGoesTo(own(status: "deleted")))
    }

    func testTheDetailLineEndsWithNotReadAloudOnlyForAGoToRow() {
        XCTAssertEqual(SilentMarginWords.detail("Sam · 12:40", goesTo: true), "Sam · 12:40 · Not read aloud")
        XCTAssertEqual(SilentMarginWords.detail("Sam · 12:40", goesTo: false), "Sam · 12:40")
        XCTAssertEqual(SilentMarginWords.detail("", goesTo: true), " · Not read aloud", "an empty line is the caller's to avoid")
    }

    func testTheHintNamesTheSourceTheListenerHas() {
        XCTAssertEqual(SilentMarginWords.hint(noun: .episode), "Moves the episode here and plays on. Nothing is read aloud.")
        XCTAssertEqual(SilentMarginWords.hint(noun: .article), "Moves the article here and plays on. Nothing is read aloud.")
        XCTAssertEqual(SilentMarginWords.hint(noun: .pdf), "Moves the PDF here and plays on. Nothing is read aloud.")
        XCTAssertEqual(SilentMarginWords.goToTitle, "Go to this moment in the source")
        XCTAssertEqual(SilentMarginWords.goToLabel, "Go to this moment")
    }

    // MARK: The landing built from a row

    func testALandingOnAnEpisodeMarginIsAtItsTimeWithTheSendersNameAndWords() {
        let margin = friend("  Listen to this part.  ", senderReadAloud: false)
        let landing = SilentMarginLanding(going: margin, in: layer(), itemId: "item-1", textUnit: .characters(perSecond: 15))
        XCTAssertEqual(landing?.position, 9_000)
        XCTAssertEqual(landing?.unit, .milliseconds)
        XCTAssertEqual(landing?.words, "Listen to this part.")
        XCTAssertEqual(landing?.subject.name, "Sam")
        XCTAssertEqual(landing?.marginId, "imported-1")
        XCTAssertEqual(landing?.isApproximate, false)
        XCTAssertEqual(landing?.card(noun: .episode).headline, "Margin from Sam is here")
    }

    func testALandingOnAGuessedPlaceSaysAboutHere() {
        let margin = friend(senderReadAloud: false, senderMs: 9_000, .init(evidenceClass: .unresolved))
        let landing = SilentMarginLanding(going: margin, in: layer(), itemId: "item-1", textUnit: .milliseconds)
        XCTAssertEqual(landing?.isApproximate, true, "the sender's own time is a guess in this copy")
        XCTAssertEqual(landing?.card(noun: .episode).headline, "Margin from Sam is about here")
    }

    func testALandingOnAPassageOfTextUsesTheCharacterOffsetAndTheTextUnit() {
        let unit = SkimStops.PositionUnit.characters(perSecond: 15)
        let margin = friend(senderReadAloud: false, senderMs: nil, .init(evidenceClass: .articleTextVerified, localStartChar: 1_200))
        let landing = SilentMarginLanding(going: margin, in: layer(), itemId: "item-1", textUnit: unit)
        XCTAssertEqual(landing?.position, 1_200)
        XCTAssertEqual(landing?.unit, unit)
        XCTAssertEqual(landing?.isApproximate, false)
    }

    func testALandingWithNoNameOrNoWordsAndOneWithNoPlace() {
        let nameless = SilentMarginLanding(going: friend("", senderReadAloud: false), in: layer(label: nil), itemId: "item-1", textUnit: .milliseconds)
        XCTAssertNil(nameless?.words, "nothing worth showing: the card says Not read aloud")
        XCTAssertNil(nameless?.subject.name)
        XCTAssertEqual(nameless?.card(noun: .article).headline, "Shared Margin is here")
        XCTAssertEqual(nameless?.card(noun: .article).detail, "Not read aloud. The article plays on.")
        XCTAssertNil(SilentMarginLanding(
            going: friend(senderMs: nil, .init(evidenceClass: .unresolved)), in: layer(), itemId: "item-1", textUnit: .milliseconds))
    }
}
