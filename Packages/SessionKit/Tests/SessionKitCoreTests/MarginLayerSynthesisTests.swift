import Foundation
import XCTest
@testable import SessionKit

/// #475: co-op hot spots with attribution, and a citation check for a model's summary.
final class MarginLayerSynthesisTests: XCTestCase {
    private let itemId = "episode-1"

    // MARK: Input

    func testLayersTheListenerLeftOutNeverReachTheInput() throws {
        let layers = [
            layer("ana", "Ana"),
            layer("ben", "Ben", enabled: false),
            layer("cy", "Cy"),
            layer("dee", "Dee", deleted: true),
            layer("other-item", "Eve", itemId: "episode-2"),
        ]
        let margins = [
            shared("ana-1", layer: "ana", at: 10_000, "ANA-TEXT"),
            shared("ben-1", layer: "ben", at: 10_000, "BEN-DISABLED-TEXT"),
            shared("cy-1", layer: "cy", at: 10_000, "CY-UNCHOSEN-TEXT"),
            shared("dee-1", layer: "dee", at: 10_000, "DEE-DELETED-TEXT"),
            shared("eve-1", layer: "other-item", at: 10_000, "EVE-OTHER-ITEM-TEXT"),
        ]
        let chosen: Set = ["ana", "ben", "dee", "other-item"]
        let input = MarginLayerSynthesis.input(
            itemId: itemId, layers: layers, interjections: margins, chosenLayerIds: chosen,
            ownMargins: [own("mine-1", at: 12_000, "MY-OWN-TEXT")], includeOwnMargins: false
        )
        let serialized = String(decoding: try input.serialized(), as: UTF8.self)
        XCTAssertTrue(serialized.contains("ANA-TEXT"))
        for excluded in ["BEN-DISABLED-TEXT", "CY-UNCHOSEN-TEXT", "DEE-DELETED-TEXT", "EVE-OTHER-ITEM-TEXT", "MY-OWN-TEXT"] {
            XCTAssertFalse(serialized.contains(excluded), "\(excluded) reached the model's input")
        }
        XCTAssertFalse(serialized.contains("Ben") || serialized.contains("Cy") || serialized.contains("Dee"))

        let withOwn = MarginLayerSynthesis.input(
            itemId: itemId, layers: layers, interjections: margins, chosenLayerIds: ["ana"],
            ownMargins: [own("mine-1", at: 12_000, "MY-OWN-TEXT"), own("mine-2", at: 13_000, "MY-DELETED-TEXT", status: "deleted")],
            includeOwnMargins: true
        )
        XCTAssertFalse(String(decoding: try withOwn.serialized(), as: UTF8.self).contains("MY-DELETED-TEXT"), "a deleted Margin reached the input")
        XCTAssertEqual(withOwn.placed.map(\.senderLabel), ["Ana", "you"])
        XCTAssertEqual(withOwn.placed.last?.marginId, "mine-1")
        XCTAssertNil(withOwn.placed.last?.layerId)
    }

    func testUnresolvedMarginsAreListedAsNotPlacedAndKeptOutOfHotSpots() {
        let margins = [
            shared("placed", layer: "ana", at: 60_000, "placed"),
            shared("unresolved", layer: "ana", at: 60_000, "unresolved", resolution: .init(evidenceClass: .unresolved)),
            shared("ambiguous", layer: "ana", at: 60_000, "ambiguous",
                   resolution: .init(evidenceClass: .acousticVerified, localMediaTimeMs: 60_000, isAmbiguous: true)),
            shared("absent", layer: "ana", at: 60_000, "absent",
                   resolution: .init(evidenceClass: .absentFromRecipientEdition, localMediaTimeMs: 60_000)),
        ]
        let input = MarginLayerSynthesis.input(itemId: itemId, layers: [layer("ana", "Ana")], interjections: margins, chosenLayerIds: ["ana"])
        XCTAssertEqual(input.placed.map(\.marginId), ["placed"])
        XCTAssertEqual(Set(input.notPlaced.map(\.marginId)), ["unresolved", "ambiguous", "absent"])
        XCTAssertTrue(input.notPlaced.allSatisfy { $0.anchorTimeMs == nil })
        XCTAssertEqual(MarginLayerSynthesis.hotSpots(input).flatMap(\.entries).map(\.marginId), ["placed"])
        XCTAssertTrue(MarginLayerSynthesis.digest(input).contains("Not placed:\n- Ana"))
    }

    // MARK: Hot spots

    func testHotSpotsAndDigestAreTheSameForShuffledInput() {
        let layers = [layer("ana", "Ana"), layer("ben", "Ben")]
        let margins = [
            shared("a1", layer: "ana", at: 760_000, "That's the argument", created: 2),
            shared("b1", layer: "ben", at: 770_000, "I disagree", created: 1),
            shared("a2", layer: "ana", at: 770_000, "Same second as Ben", created: 3),
            shared("b2", layer: "ben", at: 800_000, "Still 40 s from the first", created: 4),
            shared("b3", layer: "ben", at: 806_000, "46 s from the first: a new spot", created: 5),
            shared("a3", layer: "ana", at: 3_700_000, "Much later", created: 6),
        ]
        let ownMargins = [own("mine", at: 765_000, "Mine")]
        func build(_ shuffled: [ImportedCommentaryInterjection], _ layerOrder: [ImportedCommentaryLayer]) -> MarginLayerSynthesis.Input {
            MarginLayerSynthesis.input(
                itemId: itemId, layers: layerOrder, interjections: shuffled, chosenLayerIds: ["ana", "ben"],
                ownMargins: ownMargins, includeOwnMargins: true
            )
        }
        let reference = build(margins, layers)
        var generator = SeededGenerator(seed: 475)
        for _ in 0..<20 {
            let other = build(margins.shuffled(using: &generator), layers.shuffled(using: &generator))
            XCTAssertEqual(other, reference)
            XCTAssertEqual(MarginLayerSynthesis.digest(other), MarginLayerSynthesis.digest(reference))
        }

        let spots = MarginLayerSynthesis.hotSpots(reference)
        XCTAssertEqual(spots.map { $0.entries.map(\.marginId) }, [["a1", "mine", "a2", "b1", "b2"], ["b3"], ["a3"]])
        XCTAssertEqual(spots.first?.senderLabels, ["Ana", "you", "Ben"])
        XCTAssertEqual(reference.placed.map(\.citationId), ["m1", "m2", "m3", "m4", "m5", "m6", "m7"])
        XCTAssertEqual(MarginLayerSynthesis.digest(reference), """
        Near 12:40: Ana, Ben and you (5 Margins)
        - Ana [m1]: That's the argument
        - you [m2]: Mine
        - Ana [m3]: Same second as Ben
        - Ben [m4]: I disagree
        - Ben [m5]: Still 40 s from the first
        Near 13:26: Ben (1 Margin)
        - Ben [m6]: 46 s from the first: a new spot
        Near 1:01:40: Ana (1 Margin)
        - Ana [m7]: Much later
        """)
    }

    // MARK: Checking a summary

    func testCheckKeepsCitedClaimsDropsUnknownIdsAndMarksUncited() throws {
        let input = MarginLayerSynthesis.input(
            itemId: itemId,
            layers: [layer("ana", "Ana"), layer("ben", "Ben")],
            interjections: [shared("a1", layer: "ana", at: 1_000, "Funny"), shared("b1", layer: "ben", at: 2_000, "Wrong")],
            chosenLayerIds: ["ana", "ben"]
        )
        let checked = try MarginLayerSynthesis.check(
            [
                .init(text: "Ana laughed and Ben objected", citationIds: ["m1", "m2"]),
                .init(text: "Cy agreed", citationIds: ["m1", "m9"]),
                .init(text: "Everyone loved it", citationIds: []),
            ],
            against: input, modelId: "model-x", promptVersion: "coop-hotspots.v1"
        )
        XCTAssertEqual(checked.claims.map(\.text), ["Ana laughed and Ben objected", "Everyone loved it"])
        XCTAssertEqual(checked.claims.map(\.status), [.cited, .uncited])
        XCTAssertEqual(checked.dropped.map(\.text), ["Cy agreed"])
        XCTAssertEqual(checked.provenance.modelId, "model-x")
        XCTAssertEqual(checked.provenance.promptVersion, "coop-hotspots.v1")
        XCTAssertEqual(checked.provenance.inputDigest, try input.digest())
        XCTAssertEqual(checked.provenance.inputDigest.count, 64)

        let changed = MarginLayerSynthesis.input(
            itemId: itemId, layers: [layer("ana", "Ana")],
            interjections: [shared("a1", layer: "ana", at: 1_000, "Funny")], chosenLayerIds: ["ana"]
        )
        XCTAssertNotEqual(try changed.digest(), checked.provenance.inputDigest, "the digest names the exact input")
    }

    // MARK: Fixtures

    private func layer(_ id: String, _ label: String, enabled: Bool = true, deleted: Bool = false, itemId: String? = nil) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: itemId ?? self.itemId, packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
            displayLabel: label, importedAt: Date(timeIntervalSince1970: 0),
            isEnabled: enabled, deletedAt: deleted ? Date(timeIntervalSince1970: 1) : nil
        )
    }

    private func shared(
        _ id: String, layer: String, at ms: Int, _ text: String, created: TimeInterval = 0,
        resolution: ImportedAnchorResolution? = nil
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layer, packageScopedId: id, createdAt: Date(timeIntervalSince1970: created),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: ms),
            approvedTranscript: text,
            resolution: resolution ?? .init(evidenceClass: .acousticVerified, localMediaTimeMs: ms)
        )
    }

    private func own(_ id: String, at ms: Int, _ text: String, status: String = "active") -> Interjection {
        Interjection(
            id: id, itemId: itemId, sessionId: "session", targetType: .item, targetId: itemId,
            createdAt: Date(timeIntervalSince1970: 10), roughPercent: 0,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: ms),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: text, status: status
        )
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
