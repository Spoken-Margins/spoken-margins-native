import Foundation
import SessionKit
import XCTest

/// #957: the pure steps of private episode map preparation, against full expected values. The ids, generator
/// strings and status wording are saved or exported today, so each is pinned byte for byte.
final class EpisodeMapAssemblyTests: XCTestCase {
    private let minimum = 3_000

    private func landmark(
        _ id: String,
        order: Int = 0,
        start: Int,
        end: Int? = nil,
        anchor: Int? = nil,
        epoch: Int = 0,
        trigger: EpisodeFingerprintTrigger = .periodicPlayback,
        provenance: EpisodeFingerprintProvenance = .observedDecodedPlayback,
        asset: String? = nil,
        window: String? = nil,
        generator: String = "shazamkit-landmark.v1"
    ) -> EpisodeFingerprintLandmark {
        EpisodeFingerprintLandmark(
            id: id, order: order, sourceMediaStartMs: start, sourceMediaEndMs: end ?? start + 11_000,
            anchorMediaTimeMs: anchor ?? start, continuityEpoch: epoch, trigger: trigger, provenance: provenance,
            signatureAssetId: asset ?? "asset-\(id)", transcriptSketchWindowId: window, generatorVersion: generator
        )
    }

    // MARK: ids and the downloaded landmark

    func testSignatureAssetIdHasTheSavedShape() {
        XCTAssertEqual(
            EpisodeMapAssembly.signatureAssetId(safeItemComponent: "item-1", gridIndex: 7),
            "episode-signature-item-1-downloaded-7"
        )
    }

    func testDownloadedLandmarkCarriesEveryFieldTheSpineSaves() {
        let landmark = EpisodeMapAssembly.downloadedLandmark(
            safeItemComponent: "item-1", gridIndex: 2, startMs: 660_000, durationMs: 10_975
        )
        XCTAssertEqual(landmark, EpisodeFingerprintLandmark(
            id: "downloaded-landmark-2",
            order: 2,
            sourceMediaStartMs: 660_000,
            sourceMediaEndMs: 670_975,
            anchorMediaTimeMs: 660_000,
            continuityEpoch: 0,
            trigger: .downloadedPreparation,
            provenance: .downloadedSourceReference,
            signatureAssetId: "episode-signature-item-1-downloaded-2"
        ))
        XCTAssertEqual(landmark.generatorVersion, "shazamkit-landmark.v1")
        XCTAssertNil(landmark.transcriptSketchWindowId)
    }

    // MARK: resuming a run

    func testResumeRebuildsEveryFinishedLandmarkAndLeavesTheNextUnitIndexAlone() {
        let result = EpisodeMapAssembly.resumeFingerprints(
            safeItemComponent: "item-1", nextUnitIndex: 2, durationMs: 2_000_000,
            minimumEvidenceDurationMs: minimum, signatureExists: { _ in true }
        )
        XCTAssertEqual(result.landmarks.map(\.id), ["downloaded-landmark-0", "downloaded-landmark-1"])
        XCTAssertEqual(result.landmarks.map(\.sourceMediaStartMs), [60_000, 360_000])
        XCTAssertEqual(result.landmarks.map(\.sourceMediaEndMs), [71_000, 371_000], "a resumed landmark is the scheduled 11 s long")
        XCTAssertEqual(result.landmarks.map(\.signatureAssetId), [
            "episode-signature-item-1-downloaded-0", "episode-signature-item-1-downloaded-1"
        ])
        XCTAssertEqual(result.gridIndex, 2)
        XCTAssertEqual(result.startMs, 660_000)
        XCTAssertEqual(result.nextUnitIndex, 2)
    }

    func testResumeStopsAtTheFirstMissingSignatureAndLowersTheNextUnitIndexToIt() {
        var asked: [String] = []
        let result = EpisodeMapAssembly.resumeFingerprints(
            safeItemComponent: "item-1", nextUnitIndex: 4, durationMs: 2_000_000,
            minimumEvidenceDurationMs: minimum,
            signatureExists: { id in asked.append(id); return !id.hasSuffix("-downloaded-2") }
        )
        XCTAssertEqual(result.landmarks.map(\.id), ["downloaded-landmark-0", "downloaded-landmark-1"])
        XCTAssertEqual(result.gridIndex, 2)
        XCTAssertEqual(result.startMs, 660_000)
        XCTAssertEqual(result.nextUnitIndex, 2, "generation restarts at the hole")
        XCTAssertEqual(asked, [
            "episode-signature-item-1-downloaded-0",
            "episode-signature-item-1-downloaded-1",
            "episode-signature-item-1-downloaded-2"
        ], "positions after the hole are not looked at")
    }

    func testResumeWithNothingFinishedStartsAtTheFirstGridPosition() {
        let result = EpisodeMapAssembly.resumeFingerprints(
            safeItemComponent: "item-1", nextUnitIndex: 0, durationMs: 2_000_000,
            minimumEvidenceDurationMs: minimum, signatureExists: { _ in XCTFail("nothing to look up"); return false }
        )
        XCTAssertEqual(result, EpisodeMapAssembly.ResumedFingerprints(landmarks: [], gridIndex: 0, startMs: 60_000, nextUnitIndex: 0))
    }

    func testResumeStopsWhenTheNextPositionLeavesLessThanTheMinimumEvidence() {
        // Position 1 starts at 360,000 ms. With the minimum, it fits only while the episode runs to 363,000 ms.
        let fits = EpisodeMapAssembly.resumeFingerprints(
            safeItemComponent: "i", nextUnitIndex: 3, durationMs: 363_000,
            minimumEvidenceDurationMs: minimum, signatureExists: { _ in true }
        )
        XCTAssertEqual(fits.landmarks.map(\.id), ["downloaded-landmark-0", "downloaded-landmark-1"])
        XCTAssertEqual(fits.gridIndex, 2)
        XCTAssertEqual(fits.nextUnitIndex, 3, "running out of episode is not a hole")

        let oneMsShort = EpisodeMapAssembly.resumeFingerprints(
            safeItemComponent: "i", nextUnitIndex: 3, durationMs: 362_999,
            minimumEvidenceDurationMs: minimum, signatureExists: { _ in true }
        )
        XCTAssertEqual(oneMsShort.landmarks.map(\.id), ["downloaded-landmark-0"])
        XCTAssertEqual(oneMsShort.gridIndex, 1)
        XCTAssertEqual(oneMsShort.startMs, 360_000)
        XCTAssertEqual(oneMsShort.nextUnitIndex, 3)
    }

    func testResumeOnAnEpisodeShorterThanTheFirstPositionReturnsNothing() {
        let result = EpisodeMapAssembly.resumeFingerprints(
            safeItemComponent: "i", nextUnitIndex: 5, durationMs: 0,
            minimumEvidenceDurationMs: minimum, signatureExists: { _ in true }
        )
        XCTAssertEqual(result, EpisodeMapAssembly.ResumedFingerprints(landmarks: [], gridIndex: 0, startMs: 60_000, nextUnitIndex: 5))
    }

    // MARK: merging landmarks into the spine

    func testMergeKeepsOnlyPlaybackLandmarksFromTheSavedSpineOrdersByStartAndRenumbers() {
        let observed = landmark("observed-late", order: 9, start: 500_000)
        let observedEarly = landmark("observed-early", order: 4, start: 20_000)
        let sourceReference = landmark("source-ref", order: 1, start: 30_000, provenance: .sourceWindowReference)
        let previouslyDownloaded = landmark("old-download", order: 2, start: 40_000, provenance: .downloadedSourceReference)
        let generatedA = landmark("downloaded-landmark-1", order: 1, start: 360_000, trigger: .downloadedPreparation, provenance: .downloadedSourceReference)
        let generatedB = landmark("downloaded-landmark-0", order: 0, start: 60_000, trigger: .downloadedPreparation, provenance: .downloadedSourceReference)

        let merged = EpisodeMapAssembly.mergedLandmarks(
            existing: [observed, observedEarly, sourceReference, previouslyDownloaded],
            generated: [generatedA, generatedB],
            sketchWindows: []
        )

        XCTAssertEqual(merged.map(\.id), ["observed-early", "downloaded-landmark-0", "downloaded-landmark-1", "observed-late"])
        XCTAssertEqual(merged.map(\.order), [0, 1, 2, 3])
        XCTAssertEqual(merged.map(\.sourceMediaStartMs), [20_000, 60_000, 360_000, 500_000])
        XCTAssertEqual(merged.map(\.provenance), [
            .observedDecodedPlayback, .downloadedSourceReference, .downloadedSourceReference, .observedDecodedPlayback
        ])
    }

    func testMergeKeepsEveryOtherFieldOfEachLandmarkExceptTheOrderAndTheSketchWindow() {
        let source = landmark(
            "keep", order: 6, start: 100_000, end: 113_500, anchor: 101_250, epoch: 3,
            trigger: .stablePostSeek, provenance: .observedDecodedPlayback, asset: "asset-keep",
            window: "stale-window", generator: "shazamkit-landmark.v7"
        )
        let merged = EpisodeMapAssembly.mergedLandmarks(
            existing: [source], generated: [],
            sketchWindows: [TranscriptPhraseSketchWindow(id: "w-3", sourceStartMs: 90_000, sourceEndMs: 120_000, hashes: [])]
        )
        XCTAssertEqual(merged, [EpisodeFingerprintLandmark(
            id: "keep", order: 0, sourceMediaStartMs: 100_000, sourceMediaEndMs: 113_500,
            anchorMediaTimeMs: 101_250, continuityEpoch: 3, trigger: .stablePostSeek,
            provenance: .observedDecodedPlayback, signatureAssetId: "asset-keep",
            transcriptSketchWindowId: "w-3", generatorVersion: "shazamkit-landmark.v7"
        )])
    }

    func testMergeAssignsTheSketchWindowByAnchorWithAnExclusiveEndAndTheFirstWindowWinning() {
        let windows = [
            TranscriptPhraseSketchWindow(id: "w-a", sourceStartMs: 0, sourceEndMs: 30_000, hashes: []),
            TranscriptPhraseSketchWindow(id: "w-b", sourceStartMs: 30_000, sourceEndMs: 60_000, hashes: []),
            TranscriptPhraseSketchWindow(id: "w-overlap", sourceStartMs: 45_000, sourceEndMs: 90_000, hashes: [])
        ]
        // The anchor, not the start of the signed window, picks the sketch window.
        let atStart = landmark("start", start: 0, anchor: 0)
        let beforeEnd = landmark("before-end", start: 100, anchor: 29_999)
        let onBoundary = landmark("boundary", start: 200, anchor: 30_000)
        let overlapped = landmark("overlap", start: 300, anchor: 50_000)
        let pastLast = landmark("past", start: 400, anchor: 90_000)
        let anchoredAfterStart = landmark("anchored-after", start: 29_000, anchor: 31_000)

        let merged = EpisodeMapAssembly.mergedLandmarks(
            existing: [atStart, beforeEnd, onBoundary, overlapped, pastLast, anchoredAfterStart],
            generated: [], sketchWindows: windows
        )
        let windowByLandmark = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0.transcriptSketchWindowId) })
        XCTAssertEqual(windowByLandmark["start"], "w-a")
        XCTAssertEqual(windowByLandmark["before-end"], "w-a")
        XCTAssertEqual(windowByLandmark["boundary"], "w-b", "a window's end belongs to the next window")
        XCTAssertEqual(windowByLandmark["overlap"], "w-b", "the first window in the sketch's order wins")
        XCTAssertEqual(windowByLandmark["anchored-after"], "w-b")
        XCTAssertEqual(windowByLandmark["past"], .some(nil), "no window holds an anchor at the final end")
    }

    func testMergeOfNothingIsEmpty() {
        XCTAssertEqual(EpisodeMapAssembly.mergedLandmarks(existing: [], generated: [], sketchWindows: []), [])
    }

    // MARK: identity matches

    func testIdentityMatchesPlaceEveryLandmarkAtTheSameTimeOnBothSides() {
        let landmarks = [
            landmark("a", order: 0, start: 60_000, anchor: 61_000),
            landmark("b", order: 1, start: 360_000, anchor: 360_000)
        ]
        XCTAssertEqual(EpisodeMapAssembly.identityMatches(for: landmarks), [
            FingerprintLandmarkMatch(
                id: "exact-a", landmarkId: "a", sourceMediaTimeMs: 61_000, recipientMediaTimeMs: 61_000,
                acousticConfidence: 1, transcriptCorroborated: true, isUniqueWithinEpisode: true
            ),
            FingerprintLandmarkMatch(
                id: "exact-b", landmarkId: "b", sourceMediaTimeMs: 360_000, recipientMediaTimeMs: 360_000,
                acousticConfidence: 1, transcriptCorroborated: true, isUniqueWithinEpisode: true
            )
        ])
        XCTAssertEqual(EpisodeMapAssembly.identityMatches(for: []), [])
    }

    // MARK: scene text and scenes

    private func draft(
        _ id: String = "d-1", order: Int = 0, start: Int = 10_000, end: Int = 20_000,
        startSegment: String? = "seg-a", endSegment: String? = "seg-b", title: String? = nil
    ) -> EpisodeSceneDraft {
        EpisodeSceneDraft(
            id: id, order: order, startMs: start, endMs: end,
            startTranscriptSegmentId: startSegment, endTranscriptSegmentId: endSegment, publisherTitle: title
        )
    }

    func testSceneTextJoinsOverlappingSegmentsAndSkipsOnesThatOnlyTouchAnEdge() {
        let timeline = TranscriptTimeline(segments: [
            .init(id: "before", startMs: 0, endMs: 10_000, text: "touches the start"),
            .init(id: "first", startMs: 9_999, endMs: 12_000, text: "first"),
            .init(id: "middle", startMs: 12_000, endMs: 18_000, text: "middle"),
            .init(id: "last", startMs: 19_999, endMs: 25_000, text: "last"),
            .init(id: "after", startMs: 20_000, endMs: 30_000, text: "touches the end")
        ], chapters: [], durationMs: 30_000)
        XCTAssertEqual(EpisodeMapAssembly.sceneText(for: draft(), in: timeline), "first middle last")
        XCTAssertEqual(EpisodeMapAssembly.sceneText(for: draft(start: 40_000, end: 50_000), in: timeline), "")
    }

    func testAnEditorialLabelGivesTheSceneItsTitleSummaryAndEligibility() {
        let label = ListeningMapSummaryValidator.SceneLabel(
            title: "Why the bridge failed", description: "The engineers explain the failed bridge.",
            eligibility: .eligible, eligibilityReason: "Editorial discussion"
        )
        let landmarks = [landmark("near", order: 0, start: 9_000, anchor: 9_000, asset: "sig-near")]
        let scene = EpisodeMapAssembly.scene(draft: draft(title: "Chapter 1"), label: label, landmarks: landmarks)
        XCTAssertEqual(scene, PortableListeningMapScene(
            id: "d-1", order: 0,
            title: "Why the bridge failed",
            summaryText: "The engineers explain the failed bridge.",
            summaryAssetId: nil,
            summaryProvenance: .modelGenerated,
            eligibility: .eligible,
            eligibilityReason: "Editorial discussion",
            startAnchor: PortableAnchorEvidence(
                anchorType: .transcript, mediaTimeMs: 10_000, transcriptSegmentId: "seg-a",
                chapterTitle: "Why the bridge failed", machineEvidenceAssetIds: ["sig-near"]
            ),
            endAnchor: PortableAnchorEvidence(
                anchorType: .transcript, mediaTimeMs: 20_000, transcriptSegmentId: "seg-b",
                chapterTitle: "Why the bridge failed", machineEvidenceAssetIds: ["sig-near"]
            )
        ))
    }

    func testASceneWithoutALabelKeepsThePublisherTitleAndNoSummary() {
        let scene = EpisodeMapAssembly.scene(draft: draft(title: "Chapter 1"), label: nil, landmarks: [])
        XCTAssertEqual(scene, PortableListeningMapScene(
            id: "d-1", order: 0,
            title: "Chapter 1",
            summaryText: nil,
            summaryAssetId: nil,
            summaryProvenance: nil,
            eligibility: .unknown,
            eligibilityReason: nil,
            startAnchor: PortableAnchorEvidence(
                anchorType: .transcript, mediaTimeMs: 10_000, transcriptSegmentId: "seg-a",
                chapterTitle: "Chapter 1", machineEvidenceAssetIds: []
            ),
            endAnchor: PortableAnchorEvidence(
                anchorType: .transcript, mediaTimeMs: 20_000, transcriptSegmentId: "seg-b",
                chapterTitle: "Chapter 1", machineEvidenceAssetIds: []
            )
        ))
        let untitled = EpisodeMapAssembly.scene(draft: draft(startSegment: nil, endSegment: nil), label: nil, landmarks: [])
        XCTAssertNil(untitled.title)
        XCTAssertNil(untitled.startAnchor.chapterTitle)
        XCTAssertNil(untitled.startAnchor.transcriptSegmentId)
        XCTAssertNil(untitled.endAnchor.transcriptSegmentId)
    }

    func testAnExcludedSceneKeepsItsTitleAndReasonButNoSummary() {
        let label = ListeningMapSummaryValidator.SceneLabel(
            title: "Sponsor break", description: "A sponsor read.", eligibility: .excluded, eligibilityReason: "Advertisement"
        )
        let scene = EpisodeMapAssembly.scene(draft: draft(title: "Chapter 1"), label: label, landmarks: [])
        XCTAssertEqual(scene.title, "Sponsor break")
        XCTAssertNil(scene.summaryText, "only an editorial scene keeps its summary")
        XCTAssertNil(scene.summaryProvenance)
        XCTAssertEqual(scene.eligibility, .excluded)
        XCTAssertEqual(scene.eligibilityReason, "Advertisement")
        XCTAssertEqual(scene.startAnchor.chapterTitle, "Sponsor break")
    }

    func testTheNearestLandmarkByAnchorSuppliesTheMachineEvidenceAndTheFirstWinsATie() {
        let landmarks = [
            landmark("far", order: 0, start: 60_000, asset: "sig-far"),
            landmark("tie-first", order: 1, start: 8_000, asset: "sig-tie-first"),
            landmark("tie-second", order: 2, start: 12_000, asset: "sig-tie-second"),
            landmark("later", order: 3, start: 300_000, asset: "sig-later")
        ]
        // The scene starts at 10,000 ms: both tie landmarks are 2,000 ms away.
        let tied = EpisodeMapAssembly.scene(draft: draft(), label: nil, landmarks: landmarks)
        XCTAssertEqual(tied.startAnchor.machineEvidenceAssetIds, ["sig-tie-first"])
        XCTAssertEqual(tied.endAnchor.machineEvidenceAssetIds, ["sig-tie-first"], "both anchors carry the evidence nearest the start")

        // Distance is taken on the anchor, not the signed window's start.
        let anchored = [
            landmark("starts-near", order: 0, start: 10_000, anchor: 200_000, asset: "sig-starts-near"),
            landmark("anchored-near", order: 1, start: 200_000, anchor: 10_500, asset: "sig-anchored-near")
        ]
        let byAnchor = EpisodeMapAssembly.scene(draft: draft(), label: nil, landmarks: anchored)
        XCTAssertEqual(byAnchor.startAnchor.machineEvidenceAssetIds, ["sig-anchored-near"])
    }

    // MARK: strings the proposal and the status carry

    func testTheProposalGeneratorStringsAreTheExportedOnes() {
        XCTAssertEqual(EpisodeMapAssembly.proposalGenerator(foundationModelAvailable: true), "on-device-scene-map.v1")
        XCTAssertEqual(EpisodeMapAssembly.proposalGenerator(foundationModelAvailable: false), "deterministic-scene-boundaries.v1")
    }

    func testCompletionStatusWordingFollowsWhetherAnySceneKeptASummary() {
        func scene(summary: String?) -> PortableListeningMapScene {
            let label = summary.map {
                ListeningMapSummaryValidator.SceneLabel(title: "T", description: $0, eligibility: .eligible, eligibilityReason: nil)
            }
            return EpisodeMapAssembly.scene(draft: draft(), label: label, landmarks: [])
        }
        XCTAssertEqual(
            EpisodeMapAssembly.completionStatus(scenes: [scene(summary: nil), scene(summary: "A summary.")]),
            "Ready with scene summaries"
        )
        XCTAssertEqual(
            EpisodeMapAssembly.completionStatus(scenes: [scene(summary: "")]),
            "Ready with scene summaries",
            "an empty summary is still a summary; only a missing one is not"
        )
        XCTAssertEqual(
            EpisodeMapAssembly.completionStatus(scenes: [scene(summary: nil)]),
            "Fingerprint map ready; scene summaries unavailable"
        )
        XCTAssertEqual(
            EpisodeMapAssembly.completionStatus(scenes: []),
            "Fingerprint map ready; scene summaries unavailable"
        )
    }

    func testCompletionDiagnosticWording() {
        XCTAssertEqual(
            EpisodeMapAssembly.completionDiagnostic(landmarkCount: 12, sceneCount: 5),
            "complete:landmarks=12:scenes=5:transcript_deleted"
        )
    }
}
