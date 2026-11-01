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
            let request = PostResumeAudioSampleRequest(
                interjectionId: interjection.id,
                sessionId: interjection.sessionId,
                itemId: interjection.itemId,
                anchorMediaTimeMs: interjection.anchor.mediaTimeMs ?? 0,
                targetDurationMs: PodcastAnchorEvidenceGenerator.flankDurationMs
            )
            Task.detached { [weak self] in
                await self?.markPodcastAnchorEvidenceUnavailable(request: request, reason: "no_exact_local_playback_edition")
            }
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
            Task.detached { [weak self] in
                await self?.markPodcastAnchorEvidenceUnavailable(request: request, reason: "storage_unavailable")
            }
            return
        }
        let evidenceIDPrefix = podcastAnchorEvidenceID(request: request, suffix: "local")
        Task.detached { [weak self] in
            // The "pending" mark is saved before the capture starts, so the evidence it ends with can't be overwritten by it.
            await self?.markPodcastAnchorEvidencePendingLocal(request: request)
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
                do {
                    try await self?.persistPodcastAnchorEvidence(
                        request: request,
                        evidence: captured,
                        sourceExactEditionSHA256: digestAfterCapture
                    )
                    await MainActor.run {
                        self?.diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", interjection)] = "complete:\(captured.count)"
                    }
                } catch {
                    await self?.markPodcastAnchorEvidenceUnavailable(
                        request: request,
                        reason: "local_signature_persistence_failed:\(error.localizedDescription)"
                    )
                }
            } catch {
                await self?.markPodcastAnchorEvidenceUnavailable(
                    request: request,
                    reason: "local_signature_failed:\(error.localizedDescription)"
                )
            }
        }
    }

    #if canImport(AVFoundation) && canImport(ShazamKit)
    func handlePostResumePodcastEvidence(_ result: PostResumePodcastEvidenceCaptureResult) {
        switch result {
        case .captured(let capture):
            let evidenceID = podcastAnchorEvidenceID(
                request: capture.request,
                suffix: capture.windowRole == .preInterjection ? "stream-pre" : "stream-post"
            )
            let fileURL: URL
            do {
                let root = try podcastAnchorEvidenceDirectory(for: capture.request)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                fileURL = root.appending(path: "\(evidenceID).shazamsignature")
                try capture.signatureData.write(to: fileURL, options: .atomic)
            } catch {
                let request = capture.request
                let reason = "stream_signature_persistence_failed:\(error.localizedDescription)"
                Task.detached { [weak self] in
                    await self?.markPodcastAnchorEvidenceUnavailable(request: request, reason: reason)
                }
                return
            }
            Task.detached { [weak self] in
                do {
                    try await self?.persistPodcastAnchorEvidence(
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
                    await MainActor.run {
                        self?.diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", capture.request)] =
                            "complete:decoded_playback_\(capture.windowRole.rawValue):bytes=\(capture.signatureData.count)"
                    }
                } catch {
                    await self?.markPodcastAnchorEvidenceUnavailable(
                        request: capture.request,
                        reason: "stream_signature_persistence_failed:\(error.localizedDescription)"
                    )
                }
            }
        case .landmark(let landmark):
            saveSparseEpisodeFingerprintLandmark(landmark)
        case .failed(let request, let reason):
            Task.detached { [weak self] in
                guard let self else { return }
                if let interjection = await self.recordPodcastAnchorEvidenceFailureReason(request: request, reason: "stream_failed:\(reason)") {
                    await MainActor.run {
                        self.diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] = "stream_failed:\(reason)"
                        self.schedulePodcastAnchorEvidenceCapture(for: interjection)
                    }
                } else {
                    await self.markPodcastAnchorEvidenceUnavailable(request: request, reason: reason)
                }
            }
        }
    }

    /// Saves a landmark on the writer's actor, so the load, compaction and spine rewrite never hold the main thread
    /// (#2781): a skip is what cuts a landmark, and it must not leave the controls waiting. Only the Diagnostics line
    /// comes back here.
    private func saveSparseEpisodeFingerprintLandmark(_ capture: CapturedEpisodeFingerprintLandmark) {
        let key = "episodeFingerprintSpine:\(capture.itemId)"
        guard let writer = try? fingerprintLandmarkWriterForCurrentStore() else {
            diagnostics[key] = "persistence_failed:store_unavailable"
            return
        }
        let input = EpisodeFingerprintLandmarkInput(
            itemId: capture.itemId,
            sourceMediaStartMs: capture.sourceMediaStartMs,
            sourceMediaEndMs: capture.sourceMediaEndMs,
            anchorMediaTimeMs: capture.anchorMediaTimeMs,
            continuityEpoch: capture.continuityEpoch,
            gridIndex: capture.gridIndex,
            trigger: capture.trigger,
            signatureData: capture.signatureData
        )
        let captured = "captured:\(capture.trigger.rawValue):epoch=\(capture.continuityEpoch)"
        Task { [weak self] in
            do {
                try await writer.write(input)
                self?.diagnostics[key] = captured
            } catch {
                self?.diagnostics[key] = "persistence_failed:\(error.localizedDescription)"
            }
        }
    }

    /// One writer per Library, so its saves run one at a time (#2781). Kept here, not on `Gate1AppModel`, which is at
    /// its size ceiling (scripts/hot_file_ratchet.py).
    private static var fingerprintLandmarkWriters: [ObjectIdentifier: EpisodeFingerprintLandmarkWriter] = [:]

    private func fingerprintLandmarkWriterForCurrentStore() throws -> EpisodeFingerprintLandmarkWriter {
        guard let store else { throw SessionKitError.persistenceFailed("store_unavailable") }
        if let writer = Self.fingerprintLandmarkWriters[ObjectIdentifier(store)] { return writer }
        let writer = EpisodeFingerprintLandmarkWriter(
            store: store,
            episodeMapsDirectory: try applicationSupportDirectory()
                .appending(path: "SpokenMargins/EpisodeMaps", directoryHint: .isDirectory)
        )
        Self.fingerprintLandmarkWriters[ObjectIdentifier(store)] = writer
        return writer
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

    /// Applies one change to a Margin's anchor evidence off the main thread, one at a time in the order asked (#2509).
    /// Nil when there is no store or no such Margin.
    private func editPodcastAnchorEvidence(
        _ change: PodcastAnchorEvidenceEdits.Change,
        request: PostResumeAudioSampleRequest
    ) async throws -> Interjection? {
        guard let store else { return nil }
        let (interjectionId, itemId, sessionId) = (request.interjectionId, request.itemId, request.sessionId)
        return try await StoreReader(store).readInOrder(PodcastAnchorEvidenceEdits.orderKey) { store in
            try PodcastAnchorEvidenceEdits.apply(
                change, interjectionId: interjectionId, itemId: itemId, sessionId: sessionId, in: store
            )
        }
    }

    func persistPodcastAnchorEvidence(
        request: PostResumeAudioSampleRequest,
        evidence: [CapturedPodcastAnchorEvidence],
        sourceExactEditionSHA256: String?
    ) async throws {
        let change = PodcastAnchorEvidenceEdits.Change.merge(evidence, sourceExactEditionSHA256: sourceExactEditionSHA256)
        guard try await editPodcastAnchorEvidence(change, request: request) != nil else {
            throw SessionKitError.persistenceFailed("podcast_anchor_interjection_missing")
        }
        if activeItemId == request.itemId {
            refreshSelectedItemInBackground()
        }
    }

    private func markPodcastAnchorEvidenceUnavailable(
        request: PostResumeAudioSampleRequest,
        reason: String
    ) async {
        guard let interjection = try? await editPodcastAnchorEvidence(.markUnavailable(reason: reason), request: request) else {
            diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] = "unavailable:\(reason)"
            return
        }
        if activeItemId == request.itemId {
            refreshSelectedItemInBackground()
        }
        diagnostics[Self.marginDiagnosticKey("podcastAnchorEvidence", request)] =
            "unavailable:\(interjection.podcastAnchorEvidenceFailureReason ?? reason)"
        scheduleSourceWindowContextIfNeeded(for: interjection)
    }

    private func markPodcastAnchorEvidencePendingLocal(request: PostResumeAudioSampleRequest) async {
        guard (try? await editPodcastAnchorEvidence(.markPendingLocalCapture, request: request)) != nil else { return }
        if activeItemId == request.itemId {
            refreshSelectedItemInBackground()
        }
    }

    /// Stores a failure without changing capture status, so a fallback that runs next can't hide it.
    private func recordPodcastAnchorEvidenceFailureReason(
        request: PostResumeAudioSampleRequest,
        reason: String
    ) async -> Interjection? {
        try? await editPodcastAnchorEvidence(.recordFailureReason(reason), request: request)
    }
}
