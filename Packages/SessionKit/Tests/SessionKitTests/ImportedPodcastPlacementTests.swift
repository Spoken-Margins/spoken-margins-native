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

    func testAClockOnlyMarginIsPlacedApproximatelyAtTheSendersTime() {
        let records = [record(id: "a", senderMs: 18_838), record(id: "b", senderMs: 600_400)]
        let fused = ImportedPodcastPlacement.fuse(
            queries: queries(records), records: records, acoustic: [:], recipientTranscript: nil,
            layer: layer(id: "layer"), recipientDurationMs: 3_670_000)
        for (id, ms) in [("a", 18_838), ("b", 600_400)] {
            XCTAssertEqual(fused[id]?.evidenceClass, .timestampFallback, id)
            XCTAssertEqual(fused[id]?.localMediaTimeMs, ms, id)
            XCTAssertTrue(SharedMarginPrompts.isPlayable(fused[id]!), "plays during playback: \(id)")
            XCTAssertEqual(SharedMarginPlacementWording.line(for: fused[id]!), SharedMarginPlacementWording.approximate, id)
        }
        XCTAssertEqual(fused["a"]?.algorithmVersion, ImportedPodcastPlacement.clockOnlyAlgorithmVersion)
        XCTAssertEqual(ImportedPodcastPlacement.clockOnlyAlgorithmVersion, "podcast-anchor-sender-clock.v1")
    }

    func testAMarginThatSentEvidenceIsNeverPlacedByTheClock() {
        let fingerprinted = record(id: "fingerprinted", senderMs: 10_000, anchor: PortableAnchorEvidence(
            anchorType: .media, mediaTimeMs: 10_000, machineEvidenceAssetIds: ["pre"]))
        let worded = record(id: "worded", senderMs: 20_000, anchor: PortableAnchorEvidence(
            anchorType: .media, prefix: contextWords, mediaTimeMs: 20_000))
        let records = [fingerprinted, worded]
        let fused = ImportedPodcastPlacement.fuse(
            queries: queries(records), records: records, acoustic: [:], recipientTranscript: nil, layer: layer(id: "layer"))
        XCTAssertEqual(fused["fingerprinted"]?.evidenceClass, .unresolved)
        XCTAssertEqual(fused["worded"]?.evidenceClass, .unresolved)

        // The sender named their exact file, and the listener's isn't it: the clock belongs to another edition.
        let bare = [record(id: "a", senderMs: 10_000)]
        let otherFile = ImportedPodcastPlacement.fuse(
            queries: queries(bare), records: bare, acoustic: [:], recipientTranscript: nil,
            layer: layer(id: "layer", exactEditionSHA256: String(repeating: "b", count: 64)))
        XCTAssertEqual(otherFile["a"]?.evidenceClass, .unresolved)
    }

    func testTheClockIsNotTrustedWhenAPlacedMarginShowsTheCopiesDiffer() {
        let fingerprinted = PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 10_000, machineEvidenceAssetIds: ["pre"])
        let records = [record(id: "verified", senderMs: 10_000, anchor: fingerprinted), record(id: "bare", senderMs: 20_000)]
        func pass(placedAt ms: Int) -> [String: ImportedAnchorResolution] {
            ImportedPodcastPlacement.fuse(
                queries: queries(records), records: records,
                acoustic: ["verified": ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: ms, confidence: 0.9)],
                recipientTranscript: nil, layer: layer(id: "layer"))
        }
        // An advert 30 s longer before the verified Margin: the sender's clock is off here.
        XCTAssertEqual(pass(placedAt: 40_000)["bare"]?.evidenceClass, .unresolved)
        XCTAssertEqual(pass(placedAt: 40_000)["verified"]?.localMediaTimeMs, 40_000, "the verified placement is untouched")
        // The match agrees with the sender's clock, so the bare one may follow it.
        XCTAssertEqual(pass(placedAt: 11_000)["bare"]?.evidenceClass, .timestampFallback)
        XCTAssertEqual(pass(placedAt: 11_000)["bare"]?.localMediaTimeMs, 20_000)
    }

    func testTheClockIsNotTrustedAfterAnEditionRejectionOrPastTheEndOfTheCopy() {
        let fingerprinted = PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 10_000, machineEvidenceAssetIds: ["pre"])
        let records = [record(id: "rejected", senderMs: 10_000, anchor: fingerprinted), record(id: "bare", senderMs: 20_000)]
        let rejected = ImportedPodcastPlacement.fuse(
            queries: queries(records), records: records,
            acoustic: ["rejected": PodcastAcousticAnchorResolver.editionRejection],
            recipientTranscript: nil, layer: layer(id: "layer"))
        XCTAssertNil(rejected["bare"]?.localMediaTimeMs)

        let late = [record(id: "late", senderMs: 3_000_000)]
        let shorter = ImportedPodcastPlacement.fuse(
            queries: queries(late), records: late, acoustic: [:], recipientTranscript: nil,
            layer: layer(id: "layer"), recipientDurationMs: 2_000_000)
        XCTAssertEqual(shorter["late"]?.evidenceClass, .unresolved)

        var wrong = layer(id: "layer")
        wrong.sourceResolutionStatus = .wrongSource
        let wrongSource = ImportedPodcastPlacement.fuse(
            queries: queries(late), records: late, acoustic: [:], recipientTranscript: nil, layer: wrong)
        XCTAssertEqual(wrongSource["late"]?.evidenceClass, .unresolved)
    }

    /// A clock placement saved by one pass is still a Margin that sent no evidence: the next pass on the same
    /// file places it again rather than reading the saved placement as evidence and leaving it unresolved.
    func testASecondPassKeepsAClockPlacement() {
        var target = layer(id: "layer")
        var records = [record(id: "a", senderMs: 18_838)]
        for pass in 1...2 {
            let fused = ImportedPodcastPlacement.fuse(
                queries: queries(records), records: records, acoustic: [:], recipientTranscript: nil, layer: target)
            records = ImportedPodcastPlacement.apply(
                fused, to: records, layer: &target, recipientDigest: "same", hasTranscript: pass == 2)
            XCTAssertEqual(records[0].resolution.evidenceClass, .timestampFallback, "pass \(pass)")
            XCTAssertEqual(records[0].resolution.localMediaTimeMs, 18_838, "pass \(pass)")
            XCTAssertEqual(target.sourceResolutionStatus, .resolved, "pass \(pass)")
        }
    }

    // MARK: applying a pass

    func testApplyKeepsAVerifiedPlacementOnTheSameEditionAndSetsTheDigest() {
        let placed = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 45_000)
        let records = [record(id: "a", senderMs: 10_000, resolution: placed)]
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
