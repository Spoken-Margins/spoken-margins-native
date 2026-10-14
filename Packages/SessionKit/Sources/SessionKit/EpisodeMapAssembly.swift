import Foundation

/// The pure steps of private episode map preparation (#957): what the preparation run does with values it
/// already holds. The run itself, with its task, files, SQLite saves, ledger and services, stays in the app.
///
/// Every id, generator string and status wording here is saved or shown today and is kept byte for byte;
/// `EpisodeMapAssemblyTests` pins each one.
public enum EpisodeMapAssembly {
    /// The saved id of the signature file for landmark `gridIndex` of a downloaded episode.
    /// `safeItemComponent` is the item id already made safe for a path (the app's `safePodcastEvidenceComponent`).
    public static func signatureAssetId(safeItemComponent: String, gridIndex: Int) -> String {
        "episode-signature-\(safeItemComponent)-downloaded-\(gridIndex)"
    }

    /// A landmark read from the downloaded file at grid position `gridIndex`.
    /// The anchor is the start of the signed window; `durationMs` is the window's length.
    public static func downloadedLandmark(
        safeItemComponent: String,
        gridIndex: Int,
        startMs: Int,
        durationMs: Int
    ) -> EpisodeFingerprintLandmark {
        EpisodeFingerprintLandmark(
            id: "downloaded-landmark-\(gridIndex)",
            order: gridIndex,
            sourceMediaStartMs: startMs,
            sourceMediaEndMs: startMs + durationMs,
            anchorMediaTimeMs: startMs,
            continuityEpoch: 0,
            trigger: .downloadedPreparation,
            provenance: .downloadedSourceReference,
            signatureAssetId: signatureAssetId(safeItemComponent: safeItemComponent, gridIndex: gridIndex)
        )
    }

    /// Where a resumed fingerprinting run picks up.
    public struct ResumedFingerprints: Equatable, Sendable {
        /// The landmarks whose signature files are still there, in grid order.
        public let landmarks: [EpisodeFingerprintLandmark]
        /// The next grid position to generate.
        public let gridIndex: Int
        /// The media time of that grid position.
        public let startMs: Int
        /// The job's next unit index after the resume: lowered to the first missing signature, otherwise unchanged.
        public let nextUnitIndex: Int

        public init(landmarks: [EpisodeFingerprintLandmark], gridIndex: Int, startMs: Int, nextUnitIndex: Int) {
            self.landmarks = landmarks
            self.gridIndex = gridIndex
            self.startMs = startMs
            self.nextUnitIndex = nextUnitIndex
        }
    }

    /// Rebuilds the landmarks a previous run already finished (the first `nextUnitIndex` grid positions).
    ///
    /// Stops at the first grid position whose signature file is missing and lowers `nextUnitIndex` to it, so the
    /// run regenerates from the hole. Stops without changing `nextUnitIndex` when the next position would not
    /// leave `minimumEvidenceDurationMs` before the end of the episode.
    public static func resumeFingerprints(
        safeItemComponent: String,
        nextUnitIndex: Int,
        durationMs: Int,
        minimumEvidenceDurationMs: Int,
        signatureExists: (_ signatureAssetId: String) -> Bool
    ) -> ResumedFingerprints {
        var landmarks: [EpisodeFingerprintLandmark] = []
        var gridIndex = 0
        var startMs = SparseFingerprintSchedule.initialMediaTimeMs
        var resumedNextUnitIndex = nextUnitIndex
        while gridIndex < nextUnitIndex, startMs + minimumEvidenceDurationMs <= durationMs {
            let assetID = signatureAssetId(safeItemComponent: safeItemComponent, gridIndex: gridIndex)
            guard signatureExists(assetID) else {
                resumedNextUnitIndex = gridIndex
                break
            }
            landmarks.append(downloadedLandmark(
                safeItemComponent: safeItemComponent,
                gridIndex: gridIndex,
                startMs: startMs,
                durationMs: SparseFingerprintSchedule.targetDurationMs
            ))
            gridIndex += 1
            startMs += SparseFingerprintSchedule.periodicIntervalMs
        }
        return ResumedFingerprints(
            landmarks: landmarks,
            gridIndex: gridIndex,
            startMs: startMs,
            nextUnitIndex: resumedNextUnitIndex
        )
    }

    /// The spine's landmarks: the ones observed during playback that the saved spine already holds, plus the ones
    /// generated from the downloaded file, ordered by where they start in the source and renumbered from zero.
    /// Each takes the id of the sketch window its anchor falls in (a window's end is exclusive), if any.
    public static func mergedLandmarks(
        existing: [EpisodeFingerprintLandmark],
        generated: [EpisodeFingerprintLandmark],
        sketchWindows: [TranscriptPhraseSketchWindow]
    ) -> [EpisodeFingerprintLandmark] {
        let observedDuringPlayback = existing.filter { $0.provenance == .observedDecodedPlayback }
        return (observedDuringPlayback + generated)
            .sorted { $0.sourceMediaStartMs < $1.sourceMediaStartMs }
            .enumerated().map { index, landmark in
                let sketchWindow = sketchWindows.first {
                    landmark.anchorMediaTimeMs >= $0.sourceStartMs
                        && landmark.anchorMediaTimeMs < $0.sourceEndMs
                }
                return EpisodeFingerprintLandmark(
                    id: landmark.id,
                    order: index,
                    sourceMediaStartMs: landmark.sourceMediaStartMs,
                    sourceMediaEndMs: landmark.sourceMediaEndMs,
                    anchorMediaTimeMs: landmark.anchorMediaTimeMs,
                    continuityEpoch: landmark.continuityEpoch,
                    trigger: landmark.trigger,
                    provenance: landmark.provenance,
                    signatureAssetId: landmark.signatureAssetId,
                    transcriptSketchWindowId: sketchWindow?.id,
                    generatorVersion: landmark.generatorVersion
                )
            }
    }

    /// The text of the transcript segments that overlap a scene (a segment that only touches an edge is outside it).
    /// This is what the scene's label is generated and checked against.
    public static func sceneText(for draft: EpisodeSceneDraft, in timeline: TranscriptTimeline) -> String {
        timeline.segments
            .filter { $0.endMs > draft.startMs && $0.startMs < draft.endMs }
            .map(\.text)
            .joined(separator: " ")
    }

    /// One scene of the proposal, from its draft, the label the model produced for it (nil when none was accepted)
    /// and the spine's landmarks. Only a scene the model called editorial keeps a summary.
    /// The machine evidence is the signature of the landmark nearest the scene's start; the first one wins a tie.
    public static func scene(
        draft: EpisodeSceneDraft,
        label: ListeningMapSummaryValidator.SceneLabel?,
        landmarks: [EpisodeFingerprintLandmark]
    ) -> PortableListeningMapScene {
        let nearestEvidence = landmarks.min {
            abs($0.anchorMediaTimeMs - draft.startMs) < abs($1.anchorMediaTimeMs - draft.startMs)
        }?.signatureAssetId
        let machineEvidence = nearestEvidence.map { [$0] } ?? []
        let eligibility = label?.eligibility ?? .unknown
        let stored = ListeningMapSummaryValidator.storedSummary(for: label)
        return PortableListeningMapScene(
            id: draft.id,
            order: draft.order,
            title: label?.title ?? draft.publisherTitle,
            summaryText: stored.text,
            summaryAssetId: nil,
            summaryProvenance: stored.provenance,
            eligibility: eligibility,
            eligibilityReason: label?.eligibilityReason,
            startAnchor: PortableAnchorEvidence(
                anchorType: .transcript,
                mediaTimeMs: draft.startMs,
                transcriptSegmentId: draft.startTranscriptSegmentId,
                chapterTitle: label?.title ?? draft.publisherTitle,
                machineEvidenceAssetIds: machineEvidence
            ),
            endAnchor: PortableAnchorEvidence(
                anchorType: .transcript,
                mediaTimeMs: draft.endMs,
                transcriptSegmentId: draft.endTranscriptSegmentId,
                chapterTitle: label?.title ?? draft.publisherTitle,
                machineEvidenceAssetIds: machineEvidence
            )
        )
    }

    /// The proposal's `generator` string, which a sender exports and a recipient reads.
    public static func proposalGenerator(foundationModelAvailable: Bool) -> String {
        foundationModelAvailable ? "on-device-scene-map.v1" : "deterministic-scene-boundaries.v1"
    }

    /// An exact-edition identity match for every landmark: the preparation ran on the very file the listener plays,
    /// so each landmark sits at the same time on both sides.
    public static func identityMatches(for landmarks: [EpisodeFingerprintLandmark]) -> [FingerprintLandmarkMatch] {
        landmarks.map { landmark in
            FingerprintLandmarkMatch(
                id: "exact-\(landmark.id)",
                landmarkId: landmark.id,
                sourceMediaTimeMs: landmark.anchorMediaTimeMs,
                recipientMediaTimeMs: landmark.anchorMediaTimeMs,
                acousticConfidence: 1,
                transcriptCorroborated: true,
                isUniqueWithinEpisode: true
            )
        }
    }

    /// The status a finished run shows: "Ready with scene summaries" when any scene kept a summary
    /// (an empty summary counts; only a missing one does not).
    public static func completionStatus(scenes: [PortableListeningMapScene]) -> String {
        scenes.contains(where: { $0.summaryText != nil })
            ? "Ready with scene summaries"
            : "Fingerprint map ready; scene summaries unavailable"
    }

    /// The diagnostic a finished run records for the item.
    public static func completionDiagnostic(landmarkCount: Int, sceneCount: Int) -> String {
        "complete:landmarks=\(landmarkCount):scenes=\(sceneCount):transcript_deleted"
    }
}
