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

    /// An article clipped or added before a voiceover could be looked up (offline, an older build, a failed fetch)
    /// is looked up when it is opened: once per launch, and again after a failure, such as being offline.
    func retryVoiceoverLookupIfNeeded(itemId: String) {
        guard let store, sharedLinkVoiceover.mayLookUp(itemId: itemId),
              let item = try? store.loadItemSummary(id: itemId), // no article text decoded on every open (#2508)
              (item.textCharacterCount ?? 0) > 0,
              let address = item.externalReference, let url = URL(string: address),
              PublisherNarrationEvidence.mayHaveVoiceover(url),
              ((try? store.loadPublisherAudio(itemId: itemId)) ?? nil) == nil else { return }
        lookUpVoiceover(itemId: itemId, address: address, title: item.title)
    }

    private func lookUpVoiceover(itemId: String, address: String, title: String) {
        guard let url = URL(string: address), PublisherNarrationEvidence.mayHaveVoiceover(url) else { return }
        let article = BrowserTextHandoff(captureMode: .readablePage, source: BrowserTextSource(url: address, title: title), text: "")
        rememberSharedLinkVoiceover(sharedURL: url, article: article, itemId: itemId, fetched: FetchedPageMemo())
    }
}
