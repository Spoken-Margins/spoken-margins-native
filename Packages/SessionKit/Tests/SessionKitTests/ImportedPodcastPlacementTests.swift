import Foundation
@testable import SessionKit
@testable import SessionKitAudio
import XCTest

/// The rules that place an imported podcast Margin and add a layer up (#1000). They use synthetic
/// resolutions, with no audio, so each fails on its own when its rule breaks.
final class ImportedPodcastPlacementTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let contextWords = "the durable prefix has exactly enough unique words here"

    // MARK: layer status

    func testLayerStatusIsResolvedOnlyWhenEveryMarginPlaysInline() {
        let inline = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 10_000)
        let fallback = ImportedAnchorResolution(evidenceClass: .timestampFallback, localMediaTimeMs: 20_000)
        XCTAssertEqual(ImportedPodcastPlacement.layerStatus(for: [inline, fallback]), .resolved)
        XCTAssertEqual(ImportedPodcastPlacement.layerStatus(for: [inline, .init(evidenceClass: .unresolved)]), .contextOnly)
    }

    func testLayerStatusIsAmbiguousWhenAnyNonInlineMarginIsAmbiguous() {
        let inline = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 10_000)
        let ambiguous = ImportedAnchorResolution(evidenceClass: .ambiguous, isAmbiguous: true)
        let absent = ImportedAnchorResolution(evidenceClass: .absentFromRecipientEdition)
        XCTAssertEqual(ImportedPodcastPlacement.layerStatus(for: [inline, ambiguous]), .ambiguous)
        XCTAssertEqual(ImportedPodcastPlacement.layerStatus(for: [absent, ambiguous]), .ambiguous)
    }

    func testLayerStatusIsUnavailableOnlyWhenEveryMarginIsAbsentFromTheCopy() {
        let absent = ImportedAnchorResolution(evidenceClass: .absentFromRecipientEdition)
        let unresolved = ImportedAnchorResolution(evidenceClass: .unresolved)
        XCTAssertEqual(ImportedPodcastPlacement.layerStatus(for: [absent, absent]), .unavailable)
        XCTAssertEqual(ImportedPodcastPlacement.layerStatus(for: [absent, unresolved]), .contextOnly)
    }

    func testLayerStatusStringsAreThePersistedOnes() {
        XCTAssertEqual(ImportedSourceResolutionStatus.resolved.rawValue, "resolved")
        XCTAssertEqual(ImportedSourceResolutionStatus.contextOnly.rawValue, "context_only")
        XCTAssertEqual(ImportedSourceResolutionStatus.ambiguous.rawValue, "ambiguous")
        XCTAssertEqual(ImportedSourceResolutionStatus.unavailable.rawValue, "unavailable")
        XCTAssertEqual(ImportedPodcastPlacement.missingTranscriptAlgorithmVersion, "podcast-transcript-anchor.v1")
    }

    // MARK: which layers to work on

    func testLayersToWorkOnSkipDeletedNonPodcastAndEmptyLayers() {
        let keep = layer(id: "keep")
        let deleted = layer(id: "deleted", deletedAt: date)
        let article = layer(id: "article", itemType: .text)
        let empty = layer(id: "empty")
        let unreadable = layer(id: "unreadable")
        let artifactOnly = layer(id: "artifact-only", episodeMapEvidencePaths: ["signature": "path"])
        let records = [record(id: "a", senderMs: 1_000)]
        var asked: [String] = []
        let work = ImportedPodcastPlacement.podcastLayerRecords(
            layers: [keep, deleted, article, empty, unreadable, artifactOnly]
        ) { layer in
            asked.append(layer.id)
            switch layer.id {
            case "empty", "artifact-only": return []
            case "unreadable": return nil
            default: return records
            }
        }
        XCTAssertEqual(work.map { $0.0.id }, ["keep", "artifact-only"])
        XCTAssertEqual(work.map { $0.1.count }, [1, 0])
        XCTAssertEqual(asked, ["keep", "empty", "unreadable", "artifact-only"],
                       "deleted and non-podcast layers are never read")
    }

    func testRecordNeedsTranscriptOnlyWhenNotInlineAndContextIsUsable() {
        let withContext = PortableAnchorEvidence(anchorType: .media, prefix: contextWords, mediaTimeMs: 1_000)
        let withoutContext = PortableAnchorEvidence(anchorType: .media, prefix: "too short", mediaTimeMs: 1_000)
        let unresolved = ImportedAnchorResolution(evidenceClass: .unresolved)
        let ambiguous = ImportedAnchorResolution(evidenceClass: .ambiguous, isAmbiguous: true)
        let placed = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 9_000)
        func needs(_ anchor: PortableAnchorEvidence, _ resolution: ImportedAnchorResolution) -> Bool {
            ImportedPodcastPlacement.recordNeedsTranscript(
                record(id: "r", senderMs: 1_000, anchor: anchor, resolution: resolution))
        }
        XCTAssertTrue(needs(withContext, unresolved))
        XCTAssertTrue(needs(withContext, ambiguous))
        XCTAssertFalse(needs(withContext, placed))
        XCTAssertFalse(needs(withoutContext, unresolved))
    }

    // MARK: fusion

    func testWithoutATranscriptTheTranscriptSideIsUnresolvedAtTheV1Version() {
        let records = [record(id: "a", senderMs: 10_000), record(id: "b", senderMs: 20_000)]
        let acoustic = [
            "a": ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 12_000, confidence: 0.9),
            "b": ImportedAnchorResolution(evidenceClass: .unresolved)
        ]
        let fused = ImportedPodcastPlacement.fuse(
            queries: queries(records), records: records, acoustic: acoustic, recipientTranscript: nil)
        let unresolvedTranscript = ImportedAnchorResolution(
            evidenceClass: .unresolved, algorithmVersion: "podcast-transcript-anchor.v1")
        XCTAssertEqual(fused["a"], PodcastAnchorFusionResolver.fuse(
            transcript: unresolvedTranscript, acoustic: acoustic["a"]!))
        XCTAssertEqual(fused["a"]?.localMediaTimeMs, 12_000)
        XCTAssertEqual(fused["b"]?.evidenceClass, .unresolved)
        let emptyTimeline = PodcastTranscriptAnchorResolver.resolve(
            anchor: records[0].anchorEvidence, recipientTimeline: TranscriptTimeline(segments: [], chapters: []))
        XCTAssertEqual(emptyTimeline.algorithmVersion, ImportedPodcastPlacement.missingTranscriptAlgorithmVersion,
                       "the no-transcript stand-in is the resolver's own answer for an empty timeline")
    }

    func testMarginMissingFromTheAcousticAnswerStaysUnresolved() {
        let records = [record(id: "a", senderMs: 10_000)]
        let fused = ImportedPodcastPlacement.fuse(
            queries: queries(records), records: records, acoustic: [:], recipientTranscript: nil)
        XCTAssertEqual(fused["a"]?.evidenceClass, .unresolved)
        XCTAssertNil(fused["a"]?.localMediaTimeMs)
    }

    func testTranscriptAndAcousticEvidenceFuseWhenTheyAgree() {
        let prefix = "the durable prefix has exactly enough unique words here"
        let suffix = "the following suffix is also uniquely present right now"
        let timeline = TranscriptTimeline(segments: [
            .init(id: "pre", startMs: 10_000, endMs: 11_000, text: prefix),
            .init(id: "post", startMs: 12_000, endMs: 13_000, text: suffix)
        ], chapters: [])
        let anchor = PortableAnchorEvidence(anchorType: .transcript, prefix: prefix, suffix: suffix, mediaTimeMs: 11_500)
        let records = [record(id: "a", senderMs: 11_500, anchor: anchor)]
        let acoustic = ["a": ImportedAnchorResolution(
            evidenceClass: .acousticVerified, localMediaTimeMs: 11_700, confidence: 0.92)]
        let fused = ImportedPodcastPlacement.fuse(
            queries: queries(records), records: records, acoustic: acoustic, recipientTranscript: timeline)
        XCTAssertEqual(fused["a"]?.evidenceClass, .fused)
        XCTAssertEqual(fused["a"]?.localMediaTimeMs, 11_700)
    }

    func testAnOutOfOrderAcousticAnswerIsDemotedByTheMonotonicStep() {
        let records = [record(id: "a", senderMs: 10_000), record(id: "b", senderMs: 20_000)]
        let acoustic = [
            "a": ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 50_000),
            "b": ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 40_000)
        ]
        let fused = ImportedPodcastPlacement.fuse(
            queries: queries(records), records: records, acoustic: acoustic, recipientTranscript: nil)
        for id in ["a", "b"] {
            XCTAssertEqual(fused[id]?.evidenceClass, .ambiguous, id)
            XCTAssertNil(fused[id]?.localMediaTimeMs, id)
        }
    }

    func testContradictedMarginsAreDroppedBeforeInterpolationUsesThemAsAnchors() {
        // a and b contradict each other, so neither may anchor the projection of c. Without the first
        // monotonic pass c would follow b's offset (45_000); with it c follows d's (40_000).
        let records = [
            record(id: "e", senderMs: 5_000), record(id: "a", senderMs: 10_000), record(id: "b", senderMs: 20_000),
            record(id: "c", senderMs: 25_000), record(id: "d", senderMs: 40_000)
        ]
        func verified(_ ms: Int) -> ImportedAnchorResolution {
            ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: ms, confidence: 0.9)
        }
        let acoustic = ["e": verified(10_000), "a": verified(50_000), "b": verified(40_000), "d": verified(55_000)]
        let fused = ImportedPodcastPlacement.fuse(
            queries: queries(records), records: records, acoustic: acoustic, recipientTranscript: nil)
        XCTAssertEqual(fused["a"]?.evidenceClass, .ambiguous)
        XCTAssertEqual(fused["b"]?.evidenceClass, .ambiguous)
        XCTAssertEqual(fused["c"]?.evidenceClass, .mapInterpolated)
        XCTAssertEqual(fused["c"]?.localMediaTimeMs, 40_000)
        XCTAssertEqual(fused["d"]?.localMediaTimeMs, 55_000)
        XCTAssertEqual(fused["e"]?.localMediaTimeMs, 10_000)
    }

    func testAnEditionRejectionOverridesEveryFusedPlacement() {
        let records = [record(id: "a", senderMs: 10_000), record(id: "b", senderMs: 20_000)]
        let acoustic = [
            "a": ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 12_000),
            "b": PodcastAcousticAnchorResolver.editionRejection
        ]
        let fused = ImportedPodcastPlacement.fuse(
            queries: queries(records), records: records, acoustic: acoustic, recipientTranscript: nil)
        for id in ["a", "b"] {
            XCTAssertTrue(PodcastAcousticAnchorResolver.isEditionRejection(fused[id]!), id)
            XCTAssertNil(fused[id]?.localMediaTimeMs, id)
        }
    }

    // MARK: Margins sent with only a clock time (#3041)

    /// One whole pass: fuse the evidence, then apply it to the layer the way the coordinator does.
    private func pass(
        _ records: [ImportedCommentaryInterjection],
        layer target: inout ImportedCommentaryLayer,
        acoustic: [String: ImportedAnchorResolution] = [:],
        digest: String = "same",
        hasTranscript: Bool = false,
        recipientDurationMs: Int? = nil
    ) -> [ImportedCommentaryInterjection] {
        let fused = ImportedPodcastPlacement.fuse(
            queries: queries(records), records: records, acoustic: acoustic, recipientTranscript: nil)
        return ImportedPodcastPlacement.apply(
            fused, to: records, layer: &target, recipientDigest: digest, hasTranscript: hasTranscript,
            recipientDurationMs: recipientDurationMs)
    }

    func testAClockOnlyMarginIsPlacedApproximatelyAtTheSendersTime() {
        var target = layer(id: "layer")
        let placed = pass([record(id: "a", senderMs: 18_838), record(id: "b", senderMs: 600_400)],
                          layer: &target, recipientDurationMs: 3_670_000)
        for (index, ms) in [18_838, 600_400].enumerated() {
            let resolution = placed[index].resolution
            XCTAssertEqual(resolution.evidenceClass, .timestampFallback, placed[index].packageScopedId)
            XCTAssertEqual(resolution.localMediaTimeMs, ms, placed[index].packageScopedId)
            XCTAssertTrue(SharedMarginPrompts.isPlayable(resolution), "plays during playback: \(placed[index].packageScopedId)")
            XCTAssertEqual(SharedMarginPlacementWording.line(for: resolution), SharedMarginPlacementWording.approximate)
        }
        XCTAssertEqual(placed[0].resolution.algorithmVersion, ImportedPodcastPlacement.clockOnlyAlgorithmVersion)
        XCTAssertEqual(ImportedPodcastPlacement.clockOnlyAlgorithmVersion, "podcast-anchor-sender-clock.v1")
        XCTAssertEqual(target.sourceResolutionStatus, .resolved)
    }

    func testAMarginThatSentEvidenceIsNeverPlacedByTheClock() {
        let fingerprinted = record(id: "fingerprinted", senderMs: 10_000, anchor: PortableAnchorEvidence(
            anchorType: .media, mediaTimeMs: 10_000, machineEvidenceAssetIds: ["pre"]))
        let worded = record(id: "worded", senderMs: 20_000, anchor: PortableAnchorEvidence(
            anchorType: .media, prefix: contextWords, mediaTimeMs: 20_000))
        var target = layer(id: "layer")
        let placed = pass([fingerprinted, worded], layer: &target)
        XCTAssertEqual(placed.map(\.resolution.evidenceClass), [.unresolved, .unresolved])

        // The sender named their exact file, and the listener's isn't it: the clock belongs to another edition.
        var otherFile = layer(id: "layer", exactEditionSHA256: String(repeating: "b", count: 64))
        let bare = pass([record(id: "a", senderMs: 10_000)], layer: &otherFile)
        XCTAssertEqual(bare[0].resolution.evidenceClass, .unresolved)
    }

    func testTheClockIsNotTrustedWhenAPlacedMarginShowsTheCopiesDiffer() {
        let fingerprinted = PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 10_000, machineEvidenceAssetIds: ["pre"])
        let records = [record(id: "verified", senderMs: 10_000, anchor: fingerprinted), record(id: "bare", senderMs: 20_000)]
        func placed(at ms: Int) -> [ImportedCommentaryInterjection] {
            var target = layer(id: "layer")
            return pass(records, layer: &target, acoustic: [
                "verified": ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: ms, confidence: 0.9)])
        }
        // An advert 30 s longer before the verified Margin: the sender's clock is off here.
        XCTAssertEqual(placed(at: 40_000)[1].resolution.evidenceClass, .unresolved)
        XCTAssertEqual(placed(at: 40_000)[0].resolution.localMediaTimeMs, 40_000, "the verified placement is untouched")
        // The match agrees with the sender's clock, so the bare one may follow it.
        XCTAssertEqual(placed(at: 11_000)[1].resolution.evidenceClass, .timestampFallback)
        XCTAssertEqual(placed(at: 11_000)[1].resolution.localMediaTimeMs, 20_000)
    }

    /// The clock check reads the placements the layer will hold, including a verified one an earlier pass
    /// kept because this pass found nothing better. Pass 1 has no transcript, so the clock-only Margin is
    /// placed; pass 2 verifies the other Margin 30 s late, which withdraws it; pass 3 has no transcript
    /// again, so the verified placement survives, and the clock-only Margin must stay unplaced rather than
    /// follow a clock the layer itself contradicts (the audit of #3050).
    func testAKeptVerifiedPlacementThatShowsTheCopiesDifferKeepsTheClockOnlyMarginUnplaced() {
        let words = PortableAnchorEvidence(anchorType: .media, prefix: contextWords, mediaTimeMs: 10_000)
        var records = [record(id: "worded", senderMs: 10_000, anchor: words), record(id: "bare", senderMs: 20_000)]
        var target = layer(id: "layer")

        records = pass(records, layer: &target)
        XCTAssertEqual(records[1].resolution.evidenceClass, .timestampFallback, "pass 1: nothing contradicts the clock")

        records = pass(records, layer: &target, acoustic: [
            "worded": ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 40_000, confidence: 0.9)])
        XCTAssertEqual(records[0].resolution.localMediaTimeMs, 40_000)
        XCTAssertEqual(records[1].resolution.evidenceClass, .unresolved, "pass 2: the placement shows the clocks differ")

        records = pass(records, layer: &target)
        XCTAssertEqual(records[0].resolution.evidenceClass, .acousticVerified, "pass 3 keeps the verified placement")
        XCTAssertEqual(records[0].resolution.localMediaTimeMs, 40_000)
        XCTAssertEqual(records[1].resolution.evidenceClass, .unresolved, "pass 3: the kept placement still shows it")
        XCTAssertNil(records[1].resolution.localMediaTimeMs)
        XCTAssertEqual(target.sourceResolutionStatus, .contextOnly)

        // The same on a pass whose acoustic step found nothing at all (it threw, so the answer is empty).
        records = pass(records, layer: &target, acoustic: [:], hasTranscript: true)
        XCTAssertEqual(records[1].resolution.evidenceClass, .unresolved)
    }

    /// A different file is a fresh start: the earlier verified placement is not kept, so it says nothing
    /// about this copy's clock and the clock-only Margin follows the sender again.
    func testAVerifiedPlacementFromAnotherFileDoesNotStopTheClock() {
        let words = PortableAnchorEvidence(anchorType: .media, prefix: contextWords, mediaTimeMs: 10_000)
        let verified = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 40_000)
        let records = [record(id: "worded", senderMs: 10_000, anchor: words, resolution: verified),
                       record(id: "bare", senderMs: 20_000)]
        var target = layer(id: "layer", resolvedRecipientEditionSHA256: "old")
        let placed = pass(records, layer: &target, digest: "new")
        XCTAssertEqual(placed[0].resolution.evidenceClass, .unresolved)
        XCTAssertEqual(placed[1].resolution.evidenceClass, .timestampFallback)
    }

    func testTheClockIsNotTrustedAfterAnEditionRejectionOrPastTheEndOfTheCopy() {
        let fingerprinted = PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 10_000, machineEvidenceAssetIds: ["pre"])
        let records = [record(id: "rejected", senderMs: 10_000, anchor: fingerprinted), record(id: "bare", senderMs: 20_000)]
        var target = layer(id: "layer")
        let rejected = pass(records, layer: &target, acoustic: ["rejected": PodcastAcousticAnchorResolver.editionRejection])
        XCTAssertNil(rejected[1].resolution.localMediaTimeMs)

        let late = [record(id: "late", senderMs: 3_000_000)]
        var shortTarget = layer(id: "layer")
        let shorter = pass(late, layer: &shortTarget, recipientDurationMs: 2_000_000)
        XCTAssertEqual(shorter[0].resolution.evidenceClass, .unresolved)

        var wrong = layer(id: "layer")
        wrong.sourceResolutionStatus = .wrongSource
        let wrongSource = pass(late, layer: &wrong)
        XCTAssertEqual(wrongSource[0].resolution.evidenceClass, .unresolved)
    }

    /// A clock placement saved by one pass is still a Margin that sent no evidence: the next pass on the same
    /// file places it again rather than reading the saved placement as evidence and leaving it unresolved.
    func testASecondPassKeepsAClockPlacement() {
        var target = layer(id: "layer")
        var records = [record(id: "a", senderMs: 18_838)]
        for passNumber in 1...2 {
            records = pass(records, layer: &target, hasTranscript: passNumber == 2)
            XCTAssertEqual(records[0].resolution.evidenceClass, .timestampFallback, "pass \(passNumber)")
            XCTAssertEqual(records[0].resolution.localMediaTimeMs, 18_838, "pass \(passNumber)")
            XCTAssertEqual(target.sourceResolutionStatus, .resolved, "pass \(passNumber)")
        }
    }

    // MARK: applying a pass

    func testApplyKeepsAVerifiedPlacementOnTheSameEditionAndSetsTheDigest() {
        let placed = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 45_000)
        let evidenced = PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 10_000, machineEvidenceAssetIds: ["pre"])
        let records = [record(id: "a", senderMs: 10_000, anchor: evidenced, resolution: placed)]
        var sameEdition = layer(id: "layer", resolvedRecipientEditionSHA256: "same")
        let weaker = ["a": ImportedAnchorResolution(evidenceClass: .unresolved)]
        let kept = ImportedPodcastPlacement.apply(
            weaker, to: records, layer: &sameEdition, recipientDigest: "same", hasTranscript: false)
        XCTAssertEqual(kept[0].resolution, placed)
        XCTAssertEqual(sameEdition.sourceResolutionStatus, .resolved,
                       "the status follows the resolutions as stored, not the proposed ones")
        XCTAssertEqual(sameEdition.resolvedRecipientEditionSHA256, "same")

        var otherEdition = layer(id: "layer", resolvedRecipientEditionSHA256: "old")
        let replaced = ImportedPodcastPlacement.apply(
            weaker, to: records, layer: &otherEdition, recipientDigest: "new", hasTranscript: false)
        XCTAssertEqual(replaced[0].resolution.evidenceClass, .unresolved)
        XCTAssertEqual(otherEdition.sourceResolutionStatus, .contextOnly)
        XCTAssertEqual(otherEdition.resolvedRecipientEditionSHA256, "new", "set on every pass")

        var unknownEdition = layer(id: "layer")
        _ = ImportedPodcastPlacement.apply(
            [:], to: records, layer: &unknownEdition, recipientDigest: "new", hasTranscript: true)
        XCTAssertEqual(unknownEdition.resolvedRecipientEditionSHA256, "new")
    }

    func testApplyLeavesAMarginWithNoProposedPlacementAsItWas() {
        let before = ImportedAnchorResolution(evidenceClass: .ambiguous, isAmbiguous: true)
        let records = [record(id: "a", senderMs: 10_000, resolution: before)]
        var target = layer(id: "layer")
        let updated = ImportedPodcastPlacement.apply(
            [:], to: records, layer: &target, recipientDigest: "digest", hasTranscript: false)
        XCTAssertEqual(updated[0].resolution, before)
        XCTAssertEqual(target.sourceResolutionStatus, .ambiguous)
    }

    // MARK: helpers

    private func layer(
        id: String,
        itemType: SharedItemType = .podcast,
        deletedAt: Date? = nil,
        episodeMapEvidencePaths: [String: String]? = nil,
        resolvedRecipientEditionSHA256: String? = nil,
        exactEditionSHA256: String? = nil
    ) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: "item", packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: itemType, title: "Episode", exactEditionSHA256: exactEditionSHA256),
            importedAt: date, deletedAt: deletedAt, episodeMapEvidencePaths: episodeMapEvidencePaths,
            resolvedRecipientEditionSHA256: resolvedRecipientEditionSHA256)
    }

    private func record(
        id: String,
        senderMs: Int,
        anchor: PortableAnchorEvidence? = nil,
        resolution: ImportedAnchorResolution = .init(evidenceClass: .unresolved)
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: "record-\(id)", layerId: "layer", packageScopedId: id, createdAt: date,
            anchorEvidence: anchor ?? PortableAnchorEvidence(anchorType: .media, mediaTimeMs: senderMs),
            approvedTranscript: "Note \(id)", resolution: resolution)
    }

    private func queries(_ records: [ImportedCommentaryInterjection]) -> [PodcastPortableAnchorQuery] {
        records.map {
            PodcastPortableAnchorQuery(
                packageScopedId: $0.packageScopedId, senderMediaTimeMs: $0.anchorEvidence.mediaTimeMs,
                evidence: [], evidenceWasDeclared: false)
        }
    }
}
