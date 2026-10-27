import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitPersistence

/// An article with its publisher's recording and a text-to-time map plays the recording (#547), so
/// nothing is rendered ahead for its on-device voice. Kept out of `Gate1AppModel.swift` to stay under
/// its size ceiling (scripts/hot_file_ratchet.py).
extension Gate1AppModel {
    func playsPublisherAudio(itemId: String) -> Bool {
        guard let store, let item = try? store.loadItem(id: itemId) else { return false }
        return PublisherAudioPlayback.plan(for: item, record: try? store.loadPublisherAudio(itemId: itemId)) != nil
    }

    /// Why a post added from Following kept, or didn't keep, its publisher's voice (#2024): the item it was added as,
    /// the lookup's token (`not_substack:…`, `short_body:<words>`, `fetch_failed:…`, `none:<page absence>`,
    /// `found:…`), and whether a record was saved for that item.
    func recordFollowedPublisherAudio(_ outcome: String?, itemId: String?, saved: Bool) {
        diagnostics["followedPublisherAudio"] = "\(itemId ?? "not_imported"): \(outcome ?? "no_lookup"); record=\(saved ? "saved" : "none")"
    }

    /// For callers that just changed the item's prepared text (a Listening Map applied, an edition imported). A
    /// not-ready startup job queued for the old text left its retry cooldown running (#2653); the new text's job is
    /// not that job, so the cooldown must not hold it back (#2692).
    func schedulePrewarmAfterPreparedTextChange(itemId: String) {
        startupAudioPreparationCooldown.clear(Self.startupAudioCooldownKeys([itemId]))
        scheduleTextAudioPrewarmIfNeeded(itemId: itemId)
    }

    func scheduleTextAudioPrewarmIfNeeded(itemId: String) {
        guard !playsPublisherAudio(itemId: itemId) else { return }
        prewarmTextAudioForOnDeviceVoice(itemId: itemId)
    }

    /// A page clipped from Safari imports from the text it carries, with no network, so clipping works in airplane
    /// mode. Only afterwards, in the background, is its post page asked for a voiceover (#810); offline, or on any
    /// failure, the article stays as imported and plays on-device speech.
    @discardableResult
    func importClippedPage(_ handoff: BrowserTextHandoff) -> Bool {
        guard let itemId = importBrowserTextItem(handoff) else { return false }
        lookUpVoiceover(itemId: itemId, address: handoff.source.url, title: handoff.source.title)
        return true
    }

    /// An article clipped or added before a voiceover could be looked up (offline, an older build, a failed fetch,
    /// or a Following import that waited for the listener, #2368) is looked up when the listener opens or starts it:
    /// once per launch, and again after a failure, such as being offline. The store is read off the main actor, and
    /// Diagnostics says why a lookup did not happen (#2789).
    func retryVoiceoverLookupIfNeeded(itemId: String) {
        guard let store else { return }
        listenForPublisherMaps()
        let alreadyLookedUp = !sharedLinkVoiceover.mayLookUp(itemId: itemId)
        Task { [weak self] in
            let read = try? await StoreReader(store).read { store -> (decision: VoiceoverLookupDecision, title: String) in
                let item = try store.loadItem(id: itemId)
                let decision = VoiceoverLookupDecision.decide(
                    text: item.text,
                    externalReference: item.externalReference,
                    hasPublisherAudioRecord: try store.loadPublisherAudio(itemId: itemId) != nil,
                    alreadyLookedUp: alreadyLookedUp
                )
                return (decision, item.title)
            }
            guard let self, let read else { return }
            self.hangTelemetry.labels.scoped("voiceLookupOnOpen") {
                switch read.decision {
                case .lookUp(let address):
                    self.noteVoiceLookup(itemId: itemId, "lookup_started")
                    self.lookUpVoiceover(itemId: itemId, address: address, title: read.title)
                case .skip(let reason):
                    self.noteVoiceLookup(itemId: itemId, "skipped:\(reason)")
                }
            }
        }
    }

    /// For callers that start or resume an item (Library Play, Continue, the play queue): the same voice lookup and
    /// map try as opening its screen (#2789). A page is read only for an item the listener acted on.
    func listenerStartedItem(itemId: String) {
        retryVoiceoverLookupIfNeeded(itemId: itemId)
        guard let store else { return }
        PublisherAudioTextMapper.resume(itemId: itemId, store: store, transcriber: sourceTranscriptionClient) { [weak self] in
            self?.diagnostics["publisherAudioTextMap"] = "\(itemId): \($0)"
        }
    }

    /// Hears when a text map is saved (it takes minutes, and a post started at once begins in on-device speech).
    private func listenForPublisherMaps() {
        PublisherAudioTextMapper.mapSaved = { [weak self] itemId in self?.publisherMapSaved(itemId: itemId) }
    }

    /// A publisher recording's text map was saved (#2789). If that article is being read aloud right now, the engine
    /// hands over to the recording at the place the voice has reached; otherwise nothing changes (a paused or other
    /// item uses the recording the next time it starts).
    private func publisherMapSaved(itemId: String) {
        guard let engine, hasActiveSession, snapshot.itemId == itemId, snapshot.status.isPlaybackActive else {
            diagnostics["publisherVoiceSwitch"] = "\(itemId): map_ready_not_playing"
            return
        }
        do {
            guard let switched = try engine.adoptPublisherAudioIfReady() else {
                diagnostics["publisherVoiceSwitch"] = "\(itemId): stayed_on_device_voice"
                return
            }
            snapshot = try applyPreferredPlaybackRate(to: switched, engine: engine)
            diagnostics["publisherVoiceSwitch"] = "\(itemId): switched_to_publisher_voice"
        } catch {
            diagnostics["publisherVoiceSwitch"] = "\(itemId): failed:\(error.localizedDescription)"
        }
    }

    private func noteVoiceLookup(itemId: String, _ outcome: String) {
        let line = "\(itemId): \(outcome)"
        if diagnostics["voiceLookupOnOpen"] != line { diagnostics["voiceLookupOnOpen"] = line }
    }

    private func lookUpVoiceover(itemId: String, address: String, title: String) {
        guard let url = URL(string: address), PublisherNarrationEvidence.mayHaveVoiceover(url) else { return }
        let article = BrowserTextHandoff(captureMode: .readablePage, source: BrowserTextSource(url: address, title: title), text: "")
        rememberSharedLinkVoiceover(sharedURL: url, article: article, itemId: itemId, fetched: FetchedPageMemo())
    }
}
