import Foundation
import SessionKit
import SessionKitPersistence

// The two engine attaches that finish a long background job (#2256, #2509): a source transcript that has just been
// transcribed, and prepared audio that has just been rendered. Each used to load, normalise and save megabytes of text
// on the main actor (measured: 4.4 s to 5.5 s for a 3-hour transcript, 7.7 s to 9.9 s for a 1.1 MB book). The store
// halves now run off the main thread through the engine's persisters; only the engine half, which reads no store row,
// and the screen updates run on the main actor. The synchronous methods stay for callers that cannot wait: they run
// the same two halves one after the other.

extension Gate1AppModel {
    // MARK: Source transcript

    func attachSourceTranscriptTimeline(_ timeline: TranscriptTimeline, itemId: String) {
        hangTelemetry.labels.scoped("sourceTranscriptAttach") {
            let attached = run { engine in snapshot = try engine.attachTranscriptTimeline(itemId: itemId, timeline: timeline) }
            finishAttachingSourceTranscriptTimeline(itemId: itemId, attached: attached)
        }
    }

    /// The same attach with its store work off the main thread. With no engine yet, or one that cannot persist, it
    /// takes the synchronous path, which installs the engine or reports the failure as it always did.
    func attachSourceTranscriptTimelineOffMain(_ timeline: TranscriptTimeline, itemId: String) async {
        guard let engine, let persister = try? engine.transcriptTimelinePersister(itemId: itemId) else {
            attachSourceTranscriptTimeline(timeline, itemId: itemId)
            return
        }
        let persisted: Result<PersistedTranscriptTimeline, Error>
        do {
            persisted = .success(try await Self.offMain { try persister.persist(itemId: itemId, timeline: timeline) })
        } catch {
            persisted = .failure(error)
        }
        // Back on the main actor. Whatever happened to the engine, the item or the screen meanwhile is read now. The
        // engine half reads no store row (EngineAttachPersistersTests); a failure of either half is reported as a
        // synchronous one is.
        hangTelemetry.labels.scoped("sourceTranscriptAttach") {
            var attached = false
            do {
                if let engine = self.engine {
                    snapshot = try engine.attachTranscriptTimeline(try persisted.get())
                    attached = true
                }
            } catch {
                reportFailure(error)
            }
            finishAttachingSourceTranscriptTimeline(itemId: itemId, attached: attached)
        }
    }

    /// What follows an attach, on the main actor: the screen and the Library catch up, then the steps that waited for
    /// the transcript. The first part runs only when the attach itself worked; the second always has.
    private func finishAttachingSourceTranscriptTimeline(itemId: String, attached: Bool) {
        let shouldGeneratePendingMap = pendingMapGenerationItemId == itemId
        if attached {
            run { _ in
                if store != nil {
                    refreshLibraryRowsInBackground(mustPublish: true) // #2505
                    // Transcript imports can finish long after a shared podcast was
                    // added. They must never retarget the playback screen away from
                    // the item/session that is still active.
                    if activeItemId == itemId { // a pending map generation reads selectedItem.chapters next, so it keeps the direct read
                        if shouldGeneratePendingMap, let store { selectedItem = try loadItemDetail(id: itemId, store: store) } else { refreshSelectedItemInBackground() }
                    }
                }
                diagnostics["sourceTranscriptionStatus"] = "complete"
                diagnostics["sourceTranscriptionItem"] = itemId
                if activeItemId == itemId {
                    sourceTranscriptStatus = "ready"
                    snapshot.sourceTranscriptStatus = "ready"
                }
            }
        }
        if shouldGeneratePendingMap, !isGeneratingListeningMap { // while the tap's map is being made, its end makes this one
            pendingMapGenerationItemId = nil
            generateListeningMap()
        }
        retrySourceWindowContexts(itemId: itemId)
        if let store { CommunityMapUploadService.shared.transcriptAttached(itemId: itemId, store: store, localAudio: { [weak self] in self?.importedPodcastRecipientLocalURLs[$0] ?? self?.podcastDownloadCoordinator?.validatedLocalURL(for: $0) }) { [weak self] in self?.diagnostics["communityMapUpload"] = $0 } }
        if let localURL = importedPodcastRecipientLocalURLs[itemId]
            ?? podcastDownloadCoordinator?.validatedLocalURL(for: itemId) {
            resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
        }
    }

    // MARK: Prepared text audio

    @discardableResult
    func attachPreparedTextAudio(
        _ prepared: PreparedTextAudio,
        itemId: String,
        preparedStatus: String = "ready",
        diagnosticStatus: String = "ready",
        replaceActivePlayback: Bool = false
    ) -> Bool {
        let attached: Result<SessionSnapshot, Error>
        do {
            if engine == nil, let store {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            attached = .success(try engine.attachPreparedTextAudio(
                itemId: itemId,
                prepared: prepared,
                replaceActivePlayback: replaceActivePlayback
            ))
        } catch {
            attached = .failure(error)
        }
        return finishAttachingPreparedTextAudio(prepared, itemId: itemId, preparedStatus: preparedStatus, diagnosticStatus: diagnosticStatus, attached: attached)
    }

    /// The same attach with its store work off the main thread. The persister decides before it writes, and writes in
    /// one transaction that checks the source text is still the one the audio was made from and, when `manifestId` is
    /// given, that a Stop or a new voice has not retired the preparation meanwhile (#2134): then nothing is saved,
    /// nothing changes on screen and the answer is false. With no engine yet, or one that cannot persist, it takes the
    /// synchronous path.
    @discardableResult
    func attachPreparedTextAudioOffMain(
        _ prepared: PreparedTextAudio,
        itemId: String,
        manifestId: String? = nil,
        preparedStatus: String = "ready",
        diagnosticStatus: String = "ready",
        replaceActivePlayback: Bool = false
    ) async -> Bool {
        guard let engine, let persister = try? engine.preparedTextAudioPersister(itemId: itemId) else {
            return attachPreparedTextAudio(prepared, itemId: itemId, preparedStatus: preparedStatus, diagnosticStatus: diagnosticStatus, replaceActivePlayback: replaceActivePlayback)
        }
        let attached: Result<SessionSnapshot, Error>
        do {
            let persisted = try await Self.offMain { try persister.persist(itemId: itemId, prepared: prepared, manifestId: manifestId) }
            // Back on the main actor, on the engine it has now. The engine half reads no store row (EngineAttachPersistersTests).
            guard let current = self.engine else { return false }
            attached = .success(try current.attachPreparedTextAudio(persisted, replaceActivePlayback: replaceActivePlayback))
        } catch PreparedTextAudioRefusal.preparationRetired {
            diagnostics["supertonicPreparedCanonicalization:\(itemId)"] = "preparation_stopped" // #2134, as the check before the save
            return false
        } catch {
            attached = .failure(error)
        }
        return finishAttachingPreparedTextAudio(prepared, itemId: itemId, preparedStatus: preparedStatus, diagnosticStatus: diagnosticStatus, attached: attached)
    }

    private func finishAttachingPreparedTextAudio(
        _ prepared: PreparedTextAudio,
        itemId: String,
        preparedStatus: String,
        diagnosticStatus: String,
        attached: Result<SessionSnapshot, Error>
    ) -> Bool {
        do {
            snapshot = try attached.get()
            if let store {
                refreshLibraryRowsInBackground(mustPublish: true) // #2505: a finished prewarm is no reason to freeze the screen
                if activeItemId == itemId { refreshSelectedItemInBackground() } else if selectedItem.id == itemId { selectedItem = try loadItemDetail(id: itemId, store: store) }
            }
            activateListeningEditionAudio(itemId: itemId, timeline: prepared.timeline)
            diagnostics["textAudioPrewarm:\(itemId)"] = diagnosticStatus
            preparedTextAudioStatus = preparedStatus
            snapshot.preparedTextAudioStatus = preparedStatus
            return true
        } catch {
            diagnostics["textAudioPrewarm:\(itemId)"] = "attach_failed:\(SafeErrorText.describe(error))"
            preparedTextAudioStatus = "failed"
            snapshot.preparedTextAudioStatus = "failed"
            return false
        }
    }
}
