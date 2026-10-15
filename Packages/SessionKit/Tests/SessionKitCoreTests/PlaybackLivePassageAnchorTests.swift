import Foundation
import XCTest
@testable import SessionKit

final class PlaybackLivePassageAnchorTests: XCTestCase {
    private typealias Passage = PlaybackLivePassage
    private let text = "One. Two. Three."

    func testSourcePositionUsesItemOwnershipAndPreparedAudioCoordinatesEvenWhilePaused() {
        var snapshot = SessionSnapshot()
        snapshot.itemId = "item"
        snapshot.targetId = "prepared.caf"
        snapshot.currentTextStart = 5
        snapshot.status = .paused
        for target in [TargetType.itemTextTTS, .transcriptBackedMedia] {
            snapshot.targetType = target.rawValue
            XCTAssertEqual(Passage.sourceOffset(snapshot: snapshot, itemID: "item", isNativeAudio: false, textLength: 16), 5)
        }
        for target in [TargetType.assistantTurnTTS, .summaryTurnTTS, .browserOwnedMedia] {
            snapshot.targetType = target.rawValue
            XCTAssertNil(Passage.sourceOffset(snapshot: snapshot, itemID: "item", isNativeAudio: false, textLength: 16))
        }
        snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
        XCTAssertNil(Passage.sourceOffset(snapshot: snapshot, itemID: "item", isNativeAudio: true, textLength: 16))
        XCTAssertNil(Passage.sourceOffset(snapshot: snapshot, itemID: "other", isNativeAudio: false, textLength: 16))
        snapshot.currentTextStart = nil
        XCTAssertNil(Passage.sourceOffset(snapshot: snapshot, itemID: "item", isNativeAudio: false, textLength: 16))
        snapshot.currentTextStart = 500
        XCTAssertEqual(Passage.sourceOffset(snapshot: snapshot, itemID: "item", isNativeAudio: false, textLength: 16), 16)
        snapshot.currentTextStart = -1
        XCTAssertEqual(Passage.sourceOffset(snapshot: snapshot, itemID: "item", isNativeAudio: false, textLength: 16), 0)
    }

    func testPreparedMediaAnchorsKeepTextCoordinatesInsteadOfTheirTime() throws {
        for type in [AnchorType.text, .transcript, .media] {
            let margin = try XCTUnwrap(Passage.Margin(own: own(type: type), itemID: "item", textLength: text.count))
            XCTAssertEqual(margin.offset, 5)
            XCTAssertEqual(Passage.window(text: text, offset: 5, margins: [margin]).sentences[1].diamonds.map(\.id), ["session::note"])
        }
        XCTAssertNil(Passage.Margin(own: own(type: .media, start: 0, end: 0), itemID: "item", textLength: text.count))
        XCTAssertNil(Passage.Margin(own: own(type: .transcript, start: 0, end: 0), itemID: "item", textLength: text.count))
        let eof = try XCTUnwrap(Passage.Margin(own: own(type: .text, start: 16, end: 16), itemID: "item", textLength: text.count))
        XCTAssertEqual(Passage.window(text: text, offset: 16, margins: [eof]).sentences.last?.diamonds.count, 1)
    }

    func testOwnAnchorRejectsWrongSourceGeneratedTargetsDeletedAndMalformedRanges() {
        for note in [own(type: .turn), own(target: .assistantTurn), own(target: .summaryTurn),
                     own(item: "other"), own(status: "deleted"), own(start: -1), own(start: 10, end: 9), own(end: 17)] {
            XCTAssertNil(Passage.Margin(own: note, itemID: "item", textLength: text.count))
        }
    }

    func testSharedAnchorUsesVerifiedRecipientTextEvenWhenSenderAndMediaClocksDiffer() throws {
        for evidence in [AnchorResolutionEvidenceClass.articleTextVerified, .exactEdition, .recipientConfirmed] {
            let note = shared(resolution: .init(evidenceClass: evidence, localStartChar: 10, localEndChar: 16, localMediaTimeMs: 90_000))
            let margin = try XCTUnwrap(Passage.Margin(shared: note, layer: layer(), itemID: "item", textLength: text.count))
            XCTAssertEqual(margin.offset, 10)
            XCTAssertEqual(Passage.window(text: text, offset: 10, margins: [margin]).sentences.last?.diamonds.map(\.id), ["shared::layer::note"])
        }
        let point = shared(resolution: .init(evidenceClass: .recipientConfirmed, localStartChar: 10))
        XCTAssertNotNil(Passage.Margin(shared: point, layer: layer(), itemID: "item", textLength: text.count))
    }

    func testSharedAnchorRejectsSenderFallbackUnverifiedAmbiguousAndInvalidPlacements() {
        for evidence in [AnchorResolutionEvidenceClass.transcriptVerified, .acousticVerified, .fused, .mapInterpolated,
                         .timestampFallback, .ambiguous, .absentFromRecipientEdition, .unresolved] {
            XCTAssertNil(Passage.Margin(shared: shared(resolution: .init(evidenceClass: evidence, localStartChar: 10)),
                                       layer: layer(), itemID: "item", textLength: text.count))
        }
        for resolution in [ImportedAnchorResolution(evidenceClass: .articleTextVerified),
                           .init(evidenceClass: .articleTextVerified, localStartChar: 10, isAmbiguous: true),
                           .init(evidenceClass: .articleTextVerified, localStartChar: -1),
                           .init(evidenceClass: .articleTextVerified, localStartChar: 17),
                           .init(evidenceClass: .articleTextVerified, localStartChar: 10, localEndChar: 9),
                           .init(evidenceClass: .articleTextVerified, localStartChar: 10, localEndChar: 17)] {
            XCTAssertNil(Passage.Margin(shared: shared(resolution: resolution), layer: layer(), itemID: "item", textLength: text.count))
        }
        let note = shared(resolution: .init(evidenceClass: .articleTextVerified, localStartChar: 10))
        for value in [layer(item: "other"), layer(deleted: true), layer(id: "wrong")] {
            XCTAssertNil(Passage.Margin(shared: note, layer: value, itemID: "item", textLength: text.count))
        }
    }

    func testIdenticalNoteIDsAcrossSessionsAndLayersRemainDistinct() throws {
        let ownIDs = try ["old", "new"].map { try XCTUnwrap(Passage.Margin(own: own(session: $0), itemID: "item", textLength: 16)).id }
        XCTAssertEqual(ownIDs, ["old::note", "new::note"])
        let sharedIDs = try ["first", "second"].map { id in
            try XCTUnwrap(Passage.Margin(shared: shared(layerID: id, resolution: .init(evidenceClass: .articleTextVerified, localStartChar: 10)),
                                        layer: layer(id: id), itemID: "item", textLength: 16)).id
        }
        XCTAssertEqual(sharedIDs, ["shared::first::note", "shared::second::note"])
    }

    private func own(type: AnchorType = .text, start: Int = 5, end: Int = 9,
                     target: InterjectionTargetType = .item, item: String = "item",
                     status: String = "active", session: String = "session") -> Interjection {
        Interjection(id: "note", itemId: item, sessionId: session, targetType: target, targetId: item,
                     createdAt: Date(timeIntervalSince1970: 1), roughPercent: 99,
                     anchor: Anchor(anchorType: type, startChar: start, endChar: end, anchorBefore: "", anchorAfter: "", mediaTimeMs: 90_000),
                     audioPath: nil, audioStatus: "missing", transcriptionStatus: "complete", transcript: "words",
                     cleanedTranscript: nil, displayText: nil, status: status)
    }

    private func shared(layerID: String = "layer", resolution: ImportedAnchorResolution) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(id: "note", layerId: layerID, packageScopedId: "note", createdAt: Date(timeIntervalSince1970: 1),
                                      anchorEvidence: PortableAnchorEvidence(anchorType: .text, startChar: 0, mediaTimeMs: 1_000),
                                      approvedTranscript: "words", resolution: resolution)
    }

    private func layer(id: String = "layer", item: String = "item", deleted: Bool = false) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(id: id, itemId: item, packageDigest: "digest", packageId: "packet",
                               itemIdentity: SharedItemIdentity(itemType: .text, title: "Source"),
                               importedAt: Date(timeIntervalSince1970: 1), deletedAt: deleted ? Date(timeIntervalSince1970: 2) : nil)
    }
}
