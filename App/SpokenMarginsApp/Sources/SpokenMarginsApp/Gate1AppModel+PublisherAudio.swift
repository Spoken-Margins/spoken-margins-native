import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitPersistence

/// An article with its publisher's recording and a text-to-time map plays the recording (#547), so
/// nothing is rendered ahead for its on-device voice. Kept out of `Gate1AppModel.swift` to stay under
/// its size ceiling (scripts/hot_file_ratchet.py).
extension Gate1AppModel {
    func playsPublisherAudio(itemId: String) -> Bool {
        // The summary: every play start asks, and the answer needs no article text (#2506).
        guard let store, let item = try? store.loadItemSummary(id: itemId) else { return false }
        return PublisherAudioPlayback.playsRecording(
            summary: item, record: try? store.loadPublisherAudio(itemId: itemId),
            choice: try? store.loadPublisherAudioChoice(itemId: itemId)) // #4640: the app's voice, if the listener chose it
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
        _ = prewarmTextAudioForPlayStart(itemId: itemId)
    }

    /// Prewarms unless the item plays its publisher's recording, and returns whether it does. A play start reads the
    /// stored plan once and uses the answer for the prewarm and for the startup protection: the engine has no
    /// session for the item yet, so it can't answer (#2508).
    func prewarmTextAudioForPlayStart(itemId: String) -> Bool {
        let playsRecording = playsPublisherAudio(itemId: itemId)
        if !playsRecording { prewarmTextAudioForOnDeviceVoice(itemId: itemId) }
        return playsRecording
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
    /// `trigger` is the listener's open or play: only those may take the article feed route (#4640).
    func retryVoiceoverLookupIfNeeded(itemId: String, trigger: VoiceoverLookupDecision.Trigger) {
        guard let store else { return }
        listenForPublisherMaps()
        let alreadyLookedUp = !sharedLinkVoiceover.mayLookUp(itemId: itemId)
        let subscriptions = feedSubscriptions
        Task { [weak self] in
            let read = try? await StoreReader(store).read { store -> (decision: VoiceoverLookupDecision, title: String) in
                // The summary, so no article text is decoded on every open (#2508).
                guard let item = try store.loadItemSummary(id: itemId) else { return (.skip(reason: "no_item"), "") }
                let decision = VoiceoverLookupDecision.decide(
                    textCharacterCount: item.textCharacterCount,
                    externalReference: item.externalReference,
                    hasPublisherAudioRecord: try store.loadPublisherAudio(itemId: itemId) != nil,
                    alreadyLookedUp: alreadyLookedUp,
                    trigger: trigger,
                    mediaType: item.mediaType,
                    externalReferenceType: item.externalReferenceType,
                    itemId: item.id,
                    siteIsFollowed: FollowedSourceMatching.isItemAlreadyFollowed(item, subscriptions: subscriptions)
                )
                return (decision, item.title)
            }
            guard let self, let read else { return }
            self.hangTelemetry.labels.scoped("voiceLookupOnOpen") {
                switch read.decision {
                case .lookUp(let address, let route):
                    self.noteVoiceLookup(itemId: itemId, "lookup_started")
                    self.lookUpVoiceover(itemId: itemId, address: address, title: read.title, route: route)
                case .skip(let reason):
                    self.noteVoiceLookup(itemId: itemId, "skipped:\(reason)")
                }
            }
        }
    }

    /// For callers that start or resume an item (Library Play, Continue, the play queue): the same voice lookup and
    /// map try as opening its screen (#2789). A page is read only for an item the listener acted on.
    /// `.queueAdvance` when the play queue moved on by itself: it never takes the article feed route.
    func listenerStartedItem(itemId: String, trigger: VoiceoverLookupDecision.Trigger = .play) {
        retryVoiceoverLookupIfNeeded(itemId: itemId, trigger: trigger)
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
            diagnostics["publisherVoiceSwitch"] = "\(itemId): failed:\(SafeErrorText.describe(error))"
        }
    }

    // MARK: Reading voice (#4640)

    /// The Reading voice row for `itemId` in Listening options: the record and the listener's choice are read off the
    /// main actor. Nil hides the row.
    func publisherAudioVoiceRow(itemId: String) async -> PublisherAudioAttribution.VoiceRow? {
        guard let store else { return nil }
        let record = try? await StoreReader(store).read { try $0.loadPublisherAudio(itemId: itemId) }
        let playingSource = snapshot.itemId == itemId ? snapshot.publisherAudioSource : nil
        // State B belongs to the item being played now; the row is hidden for any other item.
        guard playingSource != nil || (snapshot.itemId == itemId && snapshot.sessionId != nil) else { return nil }
        let site = selectedItem.id == itemId ? PublisherAudioAttribution.siteName(fromOriginalLink: selectedItem.originalSourceURL?.absoluteString) : nil
        return PublisherAudioAttribution.voiceRow(
            playingSource: playingSource, recordSource: record?.detectedFrom, siteHost: site,
            hasReadyMap: record?.textMap?.segments.isEmpty == false)
    }

    /// "Use the App's Voice": keeps the choice for this article, then reads on from the same sentence in the voice it
    /// would have with no publisher audio. Not a failure, so nothing holds the recording back afterwards.
    func useAppVoice(itemId: String) async {
        await switchPublisherVoice(itemId: itemId, prefersAppVoice: true)
    }

    /// "Play Publisher's Audio": removes the choice, tries the recording again at once even after a recent failure,
    /// and plays it from the same sentence.
    func playPublisherAudio(itemId: String) async {
        await switchPublisherVoice(itemId: itemId, prefersAppVoice: false)
    }

    private func switchPublisherVoice(itemId: String, prefersAppVoice: Bool) async {
        guard let store else { return }
        do {
            let choice = PublisherAudioChoice(itemId: itemId, prefersAppVoice: true, chosenAt: Date())
            try await StoreReader(store).read { store in
                if prefersAppVoice { try store.savePublisherAudioChoice(choice) } else { try store.deletePublisherAudioChoice(itemId: itemId) }
            }
            // The sheet belongs to the playing item; for any other item the choice is kept and nothing plays.
            guard let engine, snapshot.itemId == itemId, hasActiveSession else { return }
            // The engine switches on the main actor, as every play, pause and seek does; labelled for the hang probe.
            try hangTelemetry.labels.scoped("publisherVoiceSwitch") {
                let switched = try engine.replanVoice(itemId: itemId, retryNow: !prefersAppVoice)
                snapshot = try applyPreferredPlaybackRate(to: switched, engine: engine)
            }
            PublisherVoiceSwitchTap.expect(snapshot.publisherAudioSource)
            diagnostics["publisherVoiceSwitch"] = "\(itemId): \(prefersAppVoice ? "listener_chose_app_voice" : "listener_chose_publisher_audio")"
        } catch {
            reportFailure(error, context: "Reading voice change failed", itemId: itemId)
        }
    }

    private func noteVoiceLookup(itemId: String, _ outcome: String) {
        let line = "\(itemId): \(outcome)"
        if diagnostics["voiceLookupOnOpen"] != line { diagnostics["voiceLookupOnOpen"] = line }
    }

    /// `route` comes from `VoiceoverLookupDecision` on an open or play. With no route (a clipped page), only a Substack
    /// or Type III address is looked up, as before #4640.
    private func lookUpVoiceover(itemId: String, address: String, title: String, route: VoiceoverLookupDecision.Route? = nil) {
        guard let url = URL(string: address),
              route?.mayUseArticleFeed == true || PublisherNarrationEvidence.mayHaveVoiceover(url) || TypeIIIAudioNarration.postURL(for: url) != nil else { return }
        let article = BrowserTextHandoff(captureMode: .readablePage, source: BrowserTextSource(url: address, title: title), text: "")
        rememberSharedLinkVoiceover(sharedURL: url, article: article, itemId: itemId, fetched: FetchedPageMemo(), articleFeed: route?.mayUseArticleFeed == true)
    }
}

/// The voice a Reading voice tap switched to, so the Now pane doesn't announce the switch the listener asked for
/// (#4640): only the automatic hand-over and the fallback are announced. SwiftUI's `onChange` runs on a later
/// render than the tap, so a flag cleared when the tap returns would already be gone; the value it expects is kept
/// until the next change is seen.
@MainActor
enum PublisherVoiceSwitchTap {
    private static var expected: String??

    static func expect(_ source: String?) { expected = .some(source) }

    /// Whether this change is the one a tap asked for. Any change clears the expectation.
    static func consume(_ source: String?) -> Bool {
        defer { expected = nil }
        return expected == .some(source)
    }
}
