import Foundation
import SessionKit
import XCTest

final class EpisodeMapModelsTests: XCTestCase {
    func testExactEditionProjectionMapsSceneTimesWithoutSparseLandmarks() {
        let projection = EpisodeFingerprintAlignment.makeProjection(
            id: "short-exact-edition",
            itemId: "short-episode",
            proposalId: "short-map",
            recipientEditionSHA256: "same-bytes",
            matches: [],
            exactEdition: true
        )

        XCTAssertEqual(projection.algorithmVersion, "episode-projection.exact-edition.v1")
        XCTAssertTrue(projection.points.isEmpty)
        XCTAssertEqual(projection.projectedRecipientTime(for: 0), 0)
        XCTAssertEqual(projection.projectedRecipientTime(for: 45_000), 45_000)
    }

    func testPhraseSketchIsDeterministicBoundedAndContainsNoTranscriptText() throws {
        let salt = Data(repeating: 0x2a, count: 32)
        let transcript = "Distributed episode maps keep spoken margins aligned across dynamic editions"
        let timeline = TranscriptTimeline(
            segments: [.init(id: "s1", startMs: 0, endMs: 12_000, text: transcript)],
            chapters: [],
            durationMs: 12_000
        )

        let first = TranscriptPhraseSketchBuilder.makeArtifact(
            id: "sketch",
            itemId: "episode",
            timeline: timeline,
            salt: salt,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = TranscriptPhraseSketchBuilder.makeArtifact(
            id: "sketch",
            itemId: "episode",
            timeline: timeline,
            salt: salt,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(Data(base64Encoded: first.saltBase64)?.count, 32)
        XCTAssertLessThanOrEqual(first.windows[0].hashes.count, 24)
        XCTAssertTrue(first.windows[0].hashes.allSatisfy {
            $0.count == 32 && $0.allSatisfy(\.isHexDigit)
        })
        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self).lowercased()
        XCTAssertFalse(encoded.contains("distributed episode maps"))
    }

    func testPhraseSketchRejectsStopwordOnlyAndDoesNotMatchReorderedSpeech() {
        let salt = Data(repeating: 7, count: 32)
        XCTAssertTrue(TranscriptPhraseSketchBuilder.hashes(
            for: "the and of the and of",
            salt: salt
        ).isEmpty)
        let original = TranscriptPhraseSketchBuilder.hashes(
            for: "red planets orbit distant stars while telescopes gather spectra",
            salt: salt
        )
        let reordered = TranscriptPhraseSketchBuilder.hashes(
            for: "spectra gather telescopes while stars distant orbit planets red",
            salt: salt
        )
        XCTAssertEqual(TranscriptPhraseSketchBuilder.overlapScore(original, reordered), 0)
    }

    func testPublicSaltPermitsDictionaryConfirmationAndIsNotCryptographicAnonymity() {
        let publicSalt = Data(repeating: 0x19, count: 32)
        let published = TranscriptPhraseSketchBuilder.hashes(
            for: "support for this program comes from listeners like you",
            salt: publicSalt
        )
        let attackerGuess = TranscriptPhraseSketchBuilder.hashes(
            for: "support for this program comes from listeners like you",
            salt: publicSalt
        )

        XCTAssertFalse(published.isEmpty)
        XCTAssertEqual(published, attackerGuess)
        XCTAssertEqual(TranscriptPhraseSketchBuilder.overlapScore(published, attackerGuess), 1)
    }

    func testAlignmentInterpolatesOnlyInsideStableCorroboratedIntervals() {
        let matches = [
            match("a", source: 60_000, recipient: 70_000),
            match("b", source: 360_000, recipient: 370_000),
            match("c", source: 660_000, recipient: 700_000)
        ]
        let projection = EpisodeFingerprintAlignment.makeProjection(
            id: "projection",
            itemId: "episode",
            matches: matches
        )

        XCTAssertEqual(projection.intervals.map(\.isStable), [true, false])
        XCTAssertEqual(projection.projectedRecipientTime(for: 210_000), 220_000)
        XCTAssertNil(projection.projectedRecipientTime(for: 500_000))
    }

    func testAlignmentDropsOutOfOrderRepeatedAudioCandidate() {
        let matches = [
            match("intro", source: 60_000, recipient: 500_000, confidence: 0.4, corroborated: false),
            match("body", source: 360_000, recipient: 370_000),
            match("ending", source: 660_000, recipient: 670_000)
        ]
        let chain = EpisodeFingerprintAlignment.maximumWeightMonotonicMatches(matches)
        XCTAssertEqual(chain.map(\.landmarkId), ["body", "ending"])
    }

    func testUniqueAcousticMatchAloneRemainsApproximateWithoutIndependentCorroboration() {
        let projection = EpisodeFingerprintAlignment.makeProjection(
            id: "projection",
            itemId: "episode",
            matches: [FingerprintLandmarkMatch(
                id: "unique-acoustic",
                landmarkId: "landmark",
                sourceMediaTimeMs: 60_000,
                recipientMediaTimeMs: 75_000,
                acousticConfidence: 0.99,
                transcriptCorroborated: false,
                isUniqueWithinEpisode: true
            )]
        )

        XCTAssertEqual(projection.points.first?.confidence, .approximate)
        XCTAssertTrue(projection.intervals.isEmpty)
    }

    func testMonotonicNeighborVerifiesDirectPointsButCannotEnableInterpolationWithoutTranscript() {
        let projection = EpisodeFingerprintAlignment.makeProjection(
            id: "projection",
            itemId: "episode",
            matches: [
                match("a", source: 60_000, recipient: 70_000, corroborated: false),
                match("b", source: 360_000, recipient: 370_000, corroborated: false)
            ]
        )

        XCTAssertEqual(projection.points.map(\.confidence), [.verified, .verified])
        XCTAssertEqual(projection.intervals.map(\.isStable), [false])
        XCTAssertNil(projection.projectedRecipientTime(for: 210_000))
    }

    func testSparseScheduleDebouncesSeeksAndCoalescesGridTriggers() {
        let origin = Date(timeIntervalSince1970: 100)
        var schedule = SparseFingerprintSchedule()
        XCTAssertNil(schedule.dueGridIndex(at: 59_999))
        XCTAssertEqual(schedule.dueGridIndex(at: 60_000), 0)
        schedule.markCaptured(gridIndex: 0)
        XCTAssertNil(schedule.dueGridIndex(at: 90_000))
        XCTAssertEqual(schedule.dueGridIndex(at: 360_000), 1)

        schedule.noteSeek(at: origin)
        XCTAssertEqual(schedule.continuityEpoch, 1)
        XCTAssertFalse(schedule.isSeekStable(at: origin.addingTimeInterval(4.999)))
        XCTAssertTrue(schedule.isSeekStable(at: origin.addingTimeInterval(5)))
    }

    func testSceneSegmentationPreservesPublisherBoundsAndSplitsOnlyLongChapters() {
        let segments = stride(from: 0, to: 1_020_000, by: 30_000).enumerated().map { index, start in
            MediaTimelineSegment(
                id: "s\(index)",
                startMs: start,
                endMs: min(1_020_000, start + 30_000),
                text: "Sentence \(index)."
            )
        }
        let timeline = TranscriptTimeline(
            segments: segments,
            chapters: [
                .init(id: "short", title: "Short", startMs: 0, transcriptSegmentId: "s0"),
                .init(id: "long", title: "Long", startMs: 60_000, transcriptSegmentId: "s2")
            ],
            durationMs: 1_020_000
        )
        let drafts = EpisodeSceneSegmenter.makeDrafts(timeline: timeline)

        XCTAssertEqual(drafts.first?.startMs, 0)
        XCTAssertEqual(drafts.first?.endMs, 60_000)
        XCTAssertEqual(drafts.first?.publisherTitle, "Short")
        let longDrafts = drafts.filter { $0.publisherTitle == "Long" }
        XCTAssertFalse(longDrafts.isEmpty)
        XCTAssertTrue(longDrafts.allSatisfy {
            $0.startMs >= 60_000 && $0.endMs <= 1_020_000 && $0.endMs - $0.startMs <= 480_000
        })
    }

    func testSceneSegmentationUsesDeterministicTranscriptChangePointNearTarget() {
        let segments = stride(from: 0, to: 600_000, by: 10_000).enumerated().map { index, start in
            MediaTimelineSegment(
                id: "s\(index)",
                startMs: start,
                endMs: start + 9_000,
                text: start < 240_000
                    ? "orbit telescope planet galaxy spectrum"
                    : "recipe skillet garlic kitchen simmer"
            )
        }
        let drafts = EpisodeSceneSegmenter.makeDrafts(timeline: TranscriptTimeline(
            segments: segments,
            chapters: [],
            durationMs: 600_000
        ))

        XCTAssertEqual(drafts.map(\.startMs), [0, 240_000])
        XCTAssertEqual(drafts.map(\.endMs), [240_000, 600_000])
    }

    func testSkimBridgeStateRoundTripsWithoutChangingSourcePosition() throws {
        var snapshot = SessionSnapshot()
        snapshot.currentMediaTimeMs = 125_000
        snapshot.skimBridgeState = SkimBridgeState(
            direction: .forward,
            itemId: "episode",
            originMediaTimeMs: 125_000,
            summarySceneId: "scene-1",
            destinationSceneId: "scene-2",
            destinationMediaTimeMs: 240_000,
            summaryAssetId: "bridge",
            wasSourcePlaying: true,
            status: .playing
        )
        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(decoded.currentMediaTimeMs, 125_000)
        XCTAssertEqual(decoded.skimBridgeState?.destinationMediaTimeMs, 240_000)
    }

    private func match(
        _ id: String,
        source: Int,
        recipient: Int,
        confidence: Double = 0.95,
        corroborated: Bool = true
    ) -> FingerprintLandmarkMatch {
        FingerprintLandmarkMatch(
            id: "evidence-\(id)",
            landmarkId: id,
            sourceMediaTimeMs: source,
            recipientMediaTimeMs: recipient,
            acousticConfidence: confidence,
            transcriptCorroborated: corroborated,
            isUniqueWithinEpisode: corroborated
        )
    }
}
