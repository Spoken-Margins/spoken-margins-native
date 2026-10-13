import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Podcast anchor evidence for a Margin: capture, fingerprint landmarks and the store updates (#966).
extension Gate1AppModel {
    func schedulePodcastAnchorEvidenceCapture(for interjection: Interjection) {
        guard interjection.targetType == .item,
              let mediaTimeMs = interjection.anchor.mediaTimeMs,
              let sourceURL = podcastDownloadCoordinator?.validatedLocalURL(for: interjection.itemId),
              mediaPlaybackClient?.isUsingPlaybackURL(sourceURL, itemId: interjection.itemId) == true else {
            markPodcastAnchorEvidenceUnavailable(
                request: PostResumeAudioSampleRequest(
                    interjectionId: interjection.id,
                    sessionId: interjection.sessionId,
                    itemId: interjection.itemId,
                    anchorMediaTimeMs: interjection.anchor.mediaTimeMs ?? 0,
                    targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
                ),
                reason: "no_exact_local_playback_edition"
            )
            return
        }
        diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", interjection)] = "scheduled"
        let request = PostResumeAudioSampleRequest(
            interjectionId: interjection.id,
            sessionId: interjection.sessionId,
            itemId: interjection.itemId,
            anchorMediaTimeMs: mediaTimeMs,
            targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
        )
        guard let root = try? podcastAnchorEvidenceDirectory(for: request) else {
            markPodcastAnchorEvidenceUnavailable(request: request, reason: "storage_unavailable")
            return
        }
        markPodcastAnchorEvidencePendingLocal(request: request)
        let evidenceIDPrefix = podcastAnchorEvidenceID(request: request, suffix: "local")
        Task.detached { [weak self] in
            do {
                let digestBeforeCapture = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: sourceURL)
                let generated = try await PodcastAnchorEvidenceGenerator.generate(
                    sourceURL: sourceURL,
                    anchorMediaTimeMs: mediaTimeMs,
                    outputDirectory: root,
                    idPrefix: evidenceIDPrefix
                )
                let digestAfterCapture = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: sourceURL)
                guard digestBeforeCapture == digestAfterCapture else {
                    throw SessionKitError.persistenceFailed("podcast_anchor_source_changed_during_capture")
                }
                let captured = generated.map {
                    CapturedPodcastAnchorEvidence(
                        id: $0.id,
                        localPath: $0.fileURL.path,
                        durationMs: $0.durationMs,
                        anchorOffsetMs: $0.anchorOffsetMs,
                        provenance: .exactLocalPlaybackEdition,
                        windowRole: $0.id.hasSuffix("-pre") ? .preInterjection : .postResume
                    )
                }
                await MainActor.run {
                    do {
                        try self?.persistPodcastAnchorEvidence(
                            request: request,
                            evidence: captured,
                            sourceExactEditionSHA256: digestAfterCapture
                        )
                        self?.diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", interjection)] = "complete:\(captured.count)"
                    } catch {
                        self?.markPodcastAnchorEvidenceUnavailable(
                            request: request,
                            reason: "local_signature_persistence_failed:\(error.localizedDescription)"
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self?.markPodcastAnchorEvidenceUnavailable(
                        request: request,
                        reason: "local_signature_failed:\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    #if canImport(AVFoundation) && canImport(ShazamKit)
    func handlePostResumePodcastEvidence(_ result: PostResumePodcastEvidenceCaptureResult) {
        switch result {
        case .captured(let capture):
            do {
                let root = try podcastAnchorEvidenceDirectory(for: capture.request)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let evidenceID = podcastAnchorEvidenceID(
                    request: capture.request,
                    suffix: capture.windowRole == .preInterjection ? "stream-pre" : "stream-post"
                )
                let fileURL = root.appending(path: "\(evidenceID).shazamsignature")
                try capture.signatureData.write(to: fileURL, options: .atomic)
                try persistPodcastAnchorEvidence(
                    request: capture.request,
                    evidence: [CapturedPodcastAnchorEvidence(
                        id: evidenceID,
                        localPath: fileURL.path,
                        durationMs: capture.durationMs,
                        anchorOffsetMs: capture.anchorOffsetMs,
                        provenance: .observedDecodedPlayback,
                        windowRole: capture.windowRole == .preInterjection ? .preInterjection : .postResume
                    )],
                    sourceExactEditionSHA256: nil
                )
                diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", capture.request)] =
                    "complete:decoded_playback_\(capture.windowRole.rawValue):bytes=\(capture.signatureData.count)"
            } catch {
                markPodcastAnchorEvidenceUnavailable(
                    request: capture.request,
                    reason: "stream_signature_persistence_failed:\(error.localizedDescription)"
                )
            }
        case .landmark(let landmark):
            do {
                try persistSparseEpisodeFingerprintLandmark(landmark)
                diagnostics["episodeFingerprintSpine:\(landmark.itemId)"] =
                    "captured:\(landmark.trigger.rawValue):epoch=\(landmark.continuityEpoch)"
            } catch {
                diagnostics["episodeFingerprintSpine:\(landmark.itemId)"] =
                    "persistence_failed:\(error.localizedDescription)"
            }
        case .failed(let request, let reason):
            if let interjection = recordPodcastAnchorEvidenceFailureReason(request: request, reason: "stream_failed:\(reason)") {
                diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] = "stream_failed:\(reason)"
                schedulePodcastAnchorEvidenceCapture(for: interjection)
            } else {
                markPodcastAnchorEvidenceUnavailable(request: request, reason: reason)
            }
        }
    }

    private func persistSparseEpisodeFingerprintLandmark(
        _ capture: CapturedEpisodeFingerprintLandmark
    ) throws {
        guard let store else { throw SessionKitError.persistenceFailed("store_unavailable") }
        let safeItem = safePodcastEvidenceComponent(capture.itemId)
        let root = try applicationSupportDirectory()
            .appending(path: "SpokenMargins/EpisodeMaps", directoryHint: .isDirectory)
            .appending(path: safeItem, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suffix = capture.gridIndex.map { "grid-\($0)" }
            ?? "epoch-\(capture.continuityEpoch)-\(capture.sourceMediaStartMs)"
        let assetID = "episode-signature-\(safeItem)-\(suffix)"
        let fileURL = root.appending(path: "\(assetID).shazamsignature")
        try capture.signatureData.write(to: fileURL, options: .atomic)

        let existing = try store.loadEditionFingerprintSpine(itemId: capture.itemId)
        var landmarks = existing?.landmarks.filter { $0.signatureAssetId != assetID } ?? []
        landmarks.append(EpisodeFingerprintLandmark(
            id: "landmark-\(suffix)",
            order: landmarks.count,
            sourceMediaStartMs: capture.sourceMediaStartMs,
            sourceMediaEndMs: capture.sourceMediaEndMs,
            anchorMediaTimeMs: capture.anchorMediaTimeMs,
            continuityEpoch: capture.continuityEpoch,
            trigger: capture.trigger,
            provenance: .observedDecodedPlayback,
            signatureAssetId: assetID
        ))
        landmarks = landmarks.sorted { $0.sourceMediaStartMs < $1.sourceMediaStartMs }.enumerated().map { index, value in
            EpisodeFingerprintLandmark(
                id: value.id,
                order: index,
                sourceMediaStartMs: value.sourceMediaStartMs,
                sourceMediaEndMs: value.sourceMediaEndMs,
                anchorMediaTimeMs: value.anchorMediaTimeMs,
                continuityEpoch: value.continuityEpoch,
                trigger: value.trigger,
                provenance: value.provenance,
                signatureAssetId: value.signatureAssetId,
                transcriptSketchWindowId: value.transcriptSketchWindowId,
                generatorVersion: value.generatorVersion
            )
        }
        let item = try? store.loadItem(id: capture.itemId)
        try store.saveEditionFingerprintSpine(EditionFingerprintSpineArtifact(
            id: existing?.id ?? "episode-spine-\(safeItem)",
            itemId: capture.itemId,
            canonicalURL: item?.externalReference ?? item?.media?.url,
            producingEditionDurationMs: item?.media?.durationMs,
            producingEditionSHA256: existing?.producingEditionSHA256,
            createdAt: existing?.createdAt ?? Date(),
            landmarks: landmarks
        ))
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: assetID,
            itemId: capture.itemId,
            category: .fingerprintMap,
            relativePath: "SpokenMargins/EpisodeMaps/\(safeItem)/\(assetID).shazamsignature",
            byteCount: Int64(capture.signatureData.count),
            isReproducible: false
        ))
    }
    #endif

    func podcastAnchorEvidenceDirectory(for request: PostResumeAudioSampleRequest) throws -> URL {
        try PodcastAnchorEvidencePaths.directory(
            applicationSupport: applicationSupportDirectory(),
            sessionId: request.sessionId,
            interjectionId: request.interjectionId
        )
    }

    func podcastAnchorEvidenceID(
        request: PostResumeAudioSampleRequest,
        suffix: String
    ) -> String {
        PodcastAnchorEvidencePaths.evidenceID(
            sessionId: request.sessionId,
            interjectionId: request.interjectionId,
            suffix: suffix
        )
    }

    func safePodcastEvidenceComponent(_ value: String) -> String {
        PodcastAnchorEvidencePaths.safeComponent(value)
    }

    func storedInterjection(request: PostResumeAudioSampleRequest) -> Interjection? {
        guard let store,
              let records = try? store.loadInterjections(sessionId: request.sessionId) else { return nil }
        return records.first { $0.id == request.interjectionId && $0.itemId == request.itemId }
    }

    func persistPodcastAnchorEvidence(
        request: PostResumeAudioSampleRequest,
        evidence: [CapturedPodcastAnchorEvidence],
        sourceExactEditionSHA256: String?
    ) throws {
        guard let store,
              let interjection = try store.loadInterjections(sessionId: request.sessionId)
                .first(where: { $0.id == request.interjectionId && $0.itemId == request.itemId }) else {
            throw SessionKitError.persistenceFailed("podcast_anchor_interjection_missing")
        }
        try store.saveInterjection(PodcastAnchorEvidenceRecord.merging(
            evidence,
            sourceExactEditionSHA256: sourceExactEditionSHA256,
            into: interjection
        ))
        if activeItemId == request.itemId {
            refreshSelectedItem()
        }
    }

    private func markPodcastAnchorEvidenceUnavailable(
        request: PostResumeAudioSampleRequest,
        reason: String
    ) {
        guard let store,
              let records = try? store.loadInterjections(sessionId: request.sessionId),
              let stored = records.first(where: {
                  $0.id == request.interjectionId && $0.itemId == request.itemId
              }) else {
            diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] = "unavailable:\(reason)"
            return
        }
        let interjection = PodcastAnchorEvidenceRecord.markingUnavailable(stored, reason: reason)
        try? store.saveInterjection(interjection)
        if activeItemId == request.itemId {
            refreshSelectedItem()
        }
        diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] =
            "unavailable:\(interjection.podcastAnchorEvidenceFailureReason ?? reason)"
        scheduleSourceWindowContextIfNeeded(for: interjection)
    }

    private func markPodcastAnchorEvidencePendingLocal(request: PostResumeAudioSampleRequest) {
        guard let store,
              let records = try? store.loadInterjections(sessionId: request.sessionId),
              let stored = records.first(where: {
                  $0.id == request.interjectionId && $0.itemId == request.itemId
              }) else { return }
        try? store.saveInterjection(PodcastAnchorEvidenceRecord.markingPendingLocalCapture(stored))
        if activeItemId == request.itemId {
            refreshSelectedItem()
        }
    }

    /// Stores a failure without changing capture status, so a fallback that runs next can't hide it.
    private func recordPodcastAnchorEvidenceFailureReason(
        request: PostResumeAudioSampleRequest,
        reason: String
    ) -> Interjection? {
        guard let stored = storedInterjection(request: request) else { return nil }
        let interjection = PodcastAnchorEvidenceRecord.recordingFailureReason(reason, on: stored)
        try? store?.saveInterjection(interjection)
        return interjection
    }
}
