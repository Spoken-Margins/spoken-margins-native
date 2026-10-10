import XCTest
import SessionKit

final class SharedMarginPromptsTests: XCTestCase {
    func testEligibilityRejectsDeletedDisabledWrongSourceAndAbsentOnlyLayers() {
        let enabled = layer()
        let placed = record("placed", media: 100)
        XCTAssertTrue(SharedMarginPrompts.isPlayable(placed.resolution))
        XCTAssertTrue(SharedMarginPrompts.isLayerPlaybackEligible(enabled, records: [placed]))
        var deleted = enabled
        deleted.deletedAt = Date(timeIntervalSince1970: 1)
        var disabled = enabled
        disabled.isEnabled = false
        var wrongSource = enabled
        wrongSource.sourceResolutionStatus = .wrongSource
        let absent = record("absent", media: 100, evidence: .absentFromRecipientEdition)
        XCTAssertFalse(SharedMarginPrompts.isPlayable(absent.resolution))
        for rejected in [deleted, disabled, wrongSource] {
            XCTAssertFalse(SharedMarginPrompts.isLayerPlaybackEligible(rejected, records: [placed]))
            XCTAssertTrue(SharedMarginPrompts.prompts(layers: [rejected], recordsByLayerID: [rejected.id: [placed]],
                                                    announcedIDs: [], includeAnnounced: false).isEmpty)
        }
        XCTAssertFalse(SharedMarginPrompts.isLayerPlaybackEligible(enabled, records: [absent]))
        XCTAssertFalse(SharedMarginPrompts.isLayerPlaybackEligible(enabled, records: []))
        XCTAssertTrue(SharedMarginPrompts.prompts(layers: [enabled], recordsByLayerID: [:],
                                                announcedIDs: [], includeAnnounced: false).isEmpty)
    }

    func testNumberingCountsOnlyPlacedRecordsInPositionOrderPerLayer() {
        let first = layer()
        let second = layer(id: "second")
        let prompts = SharedMarginPrompts.prompts(
            layers: [first, second],
            recordsByLayerID: [
                first.id: [record("late", media: 300), record("absent", media: 100, evidence: .absentFromRecipientEdition),
                           record("early", text: 20), record("unresolved")],
                second.id: [record("other", media: 1, layerID: second.id)]
            ], announcedIDs: [], includeAnnounced: false
        )
        XCTAssertEqual(prompts.map(\.id), ["early", "late", "other"])
        XCTAssertEqual(prompts.map(\.index), [1, 2, 1])
        XCTAssertEqual(prompts.map(\.count), [2, 2, 1])
        XCTAssertEqual(prompts.map(\.layer.id), [first.id, first.id, second.id])
    }

    func testCrossingUsesMediaThenFallsBackToTextWhenEitherMediaTimeIsNil() {
        let both = prompt(record("both", media: 100, text: 20))
        let text = prompt(record("text", text: 10))
        let noPosition = prompt(record("none"))
        let prompts = [both, noPosition, text]
        XCTAssertEqual(SharedMarginPrompts.crossed(prompts: prompts, previous: snapshot(media: 90, text: 0),
                                                 current: snapshot(media: 110, text: 30)).map(\.id), ["text", "both"])
        // Available media times take precedence even when the text position crosses.
        XCTAssertEqual(SharedMarginPrompts.crossed(prompts: [both], previous: snapshot(media: 110, text: 0),
                                                 current: snapshot(media: 120, text: 30)).map(\.id), [])
        for times: (Int?, Int?) in [(nil, nil), (nil, 110), (90, nil)] {
            XCTAssertEqual(SharedMarginPrompts.crossed(prompts: prompts, previous: snapshot(media: times.0, text: 0),
                                                     current: snapshot(media: times.1, text: 30)).map(\.id), ["text", "both"])
        }
        for times in [(110, 90), (100, 100), (0, 99), (101, 120)] {
            XCTAssertTrue(SharedMarginPrompts.crossed(prompts: [both], previous: snapshot(media: times.0),
                                                    current: snapshot(media: times.1)).isEmpty)
        }
        for times in [(90, 100), (100, 110)] {
            XCTAssertEqual(SharedMarginPrompts.crossed(prompts: [both], previous: snapshot(media: times.0),
                                                     current: snapshot(media: times.1)).map(\.id), ["both"])
        }
        XCTAssertTrue(SharedMarginPrompts.crossed(prompts: prompts, previous: snapshot(), current: snapshot()).isEmpty)
    }

    func testPositionPrefersMediaThenTextAndSortsMissingPositionLast() {
        let records = [record("none"), record("both", media: 100, text: 1), record("text", text: 20)]
        XCTAssertEqual(records.map { SharedMarginPrompts.position($0) }, [Int.max, 100, 20])
        XCTAssertEqual(records.sorted { SharedMarginPrompts.position($0) < SharedMarginPrompts.position($1) }.map(\.id),
                       ["text", "both", "none"])
    }

    func testAnnouncedIDsAreSkippedUnlessIncludedWithoutRenumbering() {
        let records = [record("first", media: 10), record("second", media: 20)]
        let hidden = SharedMarginPrompts.prompts(layers: [layer()], recordsByLayerID: ["layer": records],
                                               announcedIDs: ["first"], includeAnnounced: false)
        XCTAssertEqual(hidden.map(\.id), ["second"])
        XCTAssertEqual(hidden.map(\.index), [2])
        XCTAssertEqual(hidden.map(\.count), [2])
        let all = SharedMarginPrompts.prompts(layers: [layer()], recordsByLayerID: ["layer": records],
                                            announcedIDs: ["first"], includeAnnounced: true)
        XCTAssertEqual(all.map(\.id), ["first", "second"])
        XCTAssertEqual(all.map(\.index), [1, 2])
    }

    func testPromptPreservesInterjectionIDAndExactSenderLabels() {
        for (label, expected): (String?, String) in [(nil, "Unsigned sender"), ("", "Unsigned sender"),
                                                   (" ", " "), ("Zoë — 朋友", "Zoë — 朋友")] {
            let note = record("local-id", media: 100)
            let prompt = ImportedCommentaryPrompt(layer: layer(label: label), interjection: note, index: 1, count: 2)
            XCTAssertEqual(prompt.id, "local-id")
            XCTAssertNotEqual(prompt.id, note.packageScopedId)
            XCTAssertEqual(prompt.senderLabel, expected)
            XCTAssertEqual(prompt.interjection, note)
            XCTAssertEqual(prompt.index, 1)
            XCTAssertEqual(prompt.count, 2)
        }
    }

    func testEqualPositionsKeepInputOrderInSelectionAndCrossing() {
        let records = [record("z", media: 100), record("a", text: 100), record("m", media: 100)]
        let selected = SharedMarginPrompts.prompts(layers: [layer()], recordsByLayerID: ["layer": records],
                                                 announcedIDs: [], includeAnnounced: false)
        XCTAssertEqual(selected.map(\.id), ["z", "a", "m"])
        XCTAssertEqual(selected.map(\.index), [1, 2, 3])
        let crossed = SharedMarginPrompts.crossed(prompts: selected, previous: snapshot(media: 90, text: 90),
                                                current: snapshot(media: 110, text: 110))
        XCTAssertEqual(crossed.map(\.id), ["z", "a", "m"])
    }

    private func layer(id: String = "layer", label: String? = nil) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(id: id, itemId: "item", packageDigest: "digest", packageId: "package",
                                itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
                                displayLabel: label, importedAt: Date(timeIntervalSince1970: 0),
                                sourceResolutionStatus: .resolved, isEnabled: true)
    }

    private func record(_ id: String, media: Int? = nil, text: Int? = nil, layerID: String = "layer",
                        evidence: AnchorResolutionEvidenceClass = .exactEdition) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(id: id, layerId: layerID, packageScopedId: "packet-\(id)",
                                       createdAt: Date(timeIntervalSince1970: 0),
                                       anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
                                       resolution: ImportedAnchorResolution(evidenceClass: evidence,
                                                                            localStartChar: text, localMediaTimeMs: media))
    }

    private func prompt(_ record: ImportedCommentaryInterjection) -> ImportedCommentaryPrompt {
        ImportedCommentaryPrompt(layer: layer(), interjection: record, index: 1, count: 1)
    }

    private func snapshot(media: Int? = nil, text: Int? = nil) -> SessionSnapshot {
        var value = SessionSnapshot()
        value.currentMediaTimeMs = media
        value.currentTextStart = text
        return value
    }
}
