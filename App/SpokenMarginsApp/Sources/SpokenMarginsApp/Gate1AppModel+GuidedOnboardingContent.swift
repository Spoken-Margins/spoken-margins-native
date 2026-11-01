import Foundation
import SessionKit
import SessionKitPersistence

/// The bundled guided tour's item and listening map, moved out of the model to keep it under its line ceiling (#540).
extension Gate1AppModel {
    static func makeBundledGuidedOnboardingItem() -> Item {
        Item(
            id: guidedOnboardingItemId,
            title: "Guided Tour: Add and Prepare Sources",
            mediaType: "guided_tour",
            text: """
            Welcome to Spoken Margins. Add text, PDF, a readable webpage, or a podcast from Add Source. You can also import a DRM-free EPUB or an MP3, M4A, M4B, or audio-bearing MP4 audiobook. Native text and EPUB chapters can be prepared for offline listening. Preparation progress, storage use, retry, and cancellation stay visible; changing playback speed does not regenerate prepared audio. Followed sources appear in New from Sources and never import until you choose an entry. Use the sleep timer for a timed pause or the end of the current chapter.
            """,
            externalReference: "bundled://guided-onboarding.v1",
            status: "ready",
            externalReferenceType: "guided_onboarding",
            sourceTitle: "Spoken Margins",
            createdAt: Date()
        )
    }

    static func makeBundledGuidedOnboardingMap() -> ListeningMap {
        let textLength = makeBundledGuidedOnboardingItem().text?.count ?? 0
        return ListeningMap(
            id: "map-guided-onboarding",
            itemId: guidedOnboardingItemId,
            overview: "Practice listening, interjecting, reviewing the timeline, and exporting a session.",
            chapters: [
                Chapter(
                    id: "guided-onboarding-core-loop",
                    title: "The Core Loop",
                    startChar: 0,
                    endChar: textLength,
                    percent: 0
                )
            ]
        )
    }

    /// Saves a downloaded tour over the bundled one. The download happens in `startOfflineServices` without holding
    /// the model, so a model dropped meanwhile is never kept alive for these writes (#2195). The item read and the
    /// three saves run off the main actor in one transaction (#2509); the rest is the main actor's.
    func applyGuidedOnboardingRefresh(_ refreshed: Result<GuidedOnboardingPayload, Error>) async {
        guard let store else { return }
        do {
            let payload = try refreshed.get()
            let priorChecksum = UserDefaults.standard.string(forKey: "guidedOnboardingAudioChecksum")
            let title = payload.manifest.title
            let audioURL = payload.audioURL.absoluteString
            let bundled = Self.makeBundledGuidedOnboardingItem()
            let asset = AudioAsset(
                id: "guided-onboarding-audio",
                itemId: bundled.id,
                audioSourceType: .nativeMediaFile,
                availability: .localPhone,
                url: audioURL,
                title: title
            )
            let timeline = SourceTranscriptTimeline(
                id: "timeline-guided-onboarding",
                itemId: bundled.id,
                createdAt: Date(),
                timeline: TranscriptTimeline(
                    segments: [],
                    chapters: [
                        MediaTimelineChapter(
                            id: "guided-onboarding-core-loop",
                            title: "The Core Loop",
                            startMs: 0,
                            transcriptSegmentId: "guided-onboarding-core-loop"
                        )
                    ]
                )
            )
            let item = try await StoreReader(store).read { store in
                try OnboardingAndOfflineAssetWrites.applyGuidedTour(
                    itemId: bundled.id, fallback: bundled,
                    edit: {
                        $0.title = title
                        $0.sourceTitle = "Spoken Margins"
                        $0.media = ItemMedia(sourceType: .nativeMediaFile, url: audioURL, nativeMediaId: "guided-onboarding-audio")
                    },
                    asset: asset, timeline: timeline, in: store)
            }
            UserDefaults.standard.set(payload.manifest.audioChecksumSHA256, forKey: "guidedOnboardingAudioChecksum")
            if payload.audioChanged, priorChecksum != nil, snapshot.itemId == item.id {
                _ = try? engine?.stopPlayback()
                snapshot = SessionSnapshot()
                diagnostics["guidedOnboardingProgress"] = "reset_for_audio_change"
            }
            try await reloadLibraryRowsOffMain(store: store)
            diagnostics["guidedOnboardingRemote"] = "ready:v\(payload.manifest.contentVersion)"
        } catch {
            diagnostics["guidedOnboardingRemote"] = "fallback:\(String(describing: type(of: error)))"
        }
    }
}
