import AVFoundation
import Foundation
import SessionKit
import SessionKitAudio

/// A friend's episode that can't play (a private feed, a removed episode): the voice reads each Margin's quote, or its
/// place, and then the sender's Margin plays (owner, 2026-11-02, #3392). What is read and in what order is
/// `CantPlayListening` (SessionKit, host-tested). This file only hands those steps to the one Margin-moment machine and
/// the one reader a written Margin already uses, so heard-marking, the chime, skip and interruptions are the ones every
/// friend Margin has. No resume flag and no second playback state machine.
extension Gate1AppModel {
    /// How long the first words get to render before the listening starts anyway. The words are short; a reading that
    /// still isn't there at its turn is passed over and the Margin plays at once (the conductor's missing-file path).
    private static let cantPlayRenderHold: TimeInterval = 6

    /// Whether the item's episode can't play, by `CantPlayListening.shouldHearWithoutEpisode`. `startStalled`: the
    /// playback screen's 30 second stall.
    func episodeCantPlay(itemId: String, startStalled: Bool) -> Bool {
        let hasFile = podcastDownloadCoordinator?.validatedLocalURL(for: itemId) != nil
        let episode = CantPlayListening.Episode(
            downloadState: podcastDownloadRecords[itemId]?.state, hasSavedAudio: hasFile, startStalled: startStalled
        )
        return CantPlayListening.shouldHearWithoutEpisode(episode, friendMargins: newSharedMargins(itemId: itemId).count)
    }

    /// Starts the friend's new Margins without the episode, when it can't play. True when this took the call: the
    /// listening starts from here (after the first words are rendered, at most `cantPlayRenderHold` seconds).
    @discardableResult
    func hearFriendMarginsWithoutEpisode(itemId: String, startStalled: Bool, entries offered: [SharedMarginReview.Entry]? = nil) -> Bool {
        guard episodeCantPlay(itemId: itemId, startStalled: startStalled) else { return false }
        let entries = offered ?? newSharedMargins(itemId: itemId)
        let title = selectedItem.id == itemId ? selectedItem.title : (try? store?.loadItemSummary(id: itemId))?.title
        let beats = CantPlayListening.plan(
            entries: entries, episodeTitle: title, voiceFor: Self.installedVoice(forLanguage:), defaultVoice: Self.defaultInstalledVoice
        )
        guard !beats.isEmpty, !rejectNavigationOrSessionMutationWhileRecording("hear_margins_without_episode") else { return false }
        endMarginMoment()
        importedCommentaryAutoPlayTask?.cancel()
        importedCommentaryAutoPlayTask = nil
        pendingImportedCommentary = nil
        _ = sharedMarginReturn.promptDismissed()
        stopImportedCommentaryPlayback(resumeSource: false)
        if snapshot.status.isPlaybackActive { pause() } // the stalled start: nothing is coming from it

        let reader = WrittenMarginReader.shared
        var readings: [String: WrittenMarginReading] = [:]
        for beat in beats { readings[beat.contextId] = beat.reading }
        var files = reader.start(readings) // the words, rendering now; their paths come from the words alone
        files.merge(WrittenMarginReadings.startingReview(for: beats.map(\.entry), voiceFile: resolvedApplicationSupportAssetURL(for:))) { words, _ in words }
        let first = beats.prefix(2).map(\.reading)
        let place = snapshot.currentMediaTimeMs ?? 0
        Task { @MainActor [weak self] in
            await reader.waitUntilSettled(first, upTo: Self.cantPlayRenderHold)
            guard let self, self.selectedItem.id == itemId, self.marginMomentConductor == nil,
                  let sequence = CantPlayListening.sequence(for: beats, itemId: itemId, placeMs: place) else { return }
            self.startCantPlayListening(sequence: sequence, beats: beats, files: files)
        }
        return true
    }

    private func startCantPlayListening(sequence: MarginMomentSequence, beats: [CantPlayListening.Beat], files: [String: URL]) {
        beats.forEach { sharedMarginOffers.markAnnounced($0.entry.interjection.id) } // the automatic prompts mustn't play them again
        var heard: [String: ImportedCommentaryInterjection] = [:]
        for beat in beats { heard[beat.marginId] = beat.entry.interjection }
        startMarginMoment(sequence: sequence, voiceURLs: files, title: "New Margins", isApproximate: false)
        guard let conductor = marginMomentConductor else { return }
        // Only a real Margin is ever marked heard, and only when its voice starts: the words have their own ids.
        conductor.onVoiceStarted = { [weak self] id in if let margin = heard[id] { self?.markSharedMarginHeard(margin) } }
        conductor.chimedMarginIds = Set(beats.filter { !$0.entry.layer.isMuted }.map(\.marginId))
        conductor.onChimeStarted = { [weak self] in self?.diagnostics["marginMoment.chime"] = "played:\($0)" }
        // Words that can't be read are passed over without a word: the Margin follows at once. A Margin that can't play
        // says so, with the words for what it is.
        conductor.onVoiceUnavailable = { [weak self] id, reason in
            self?.diagnostics["marginMoment.voiceUnavailable"] = "\(id):\(reason)"
            guard let margin = heard[id] else { return }
            self?.reportWarning(SharedMarginAudio.unavailableWords(for: margin))
        }
        diagnostics["marginMoment"] = "started:cant_play;beats=\(beats.count)"
        screen = .playback
        conductor.playTargetNow() // there is no episode to reach the first Margin: the words start now
    }

    // MARK: Voices installed on this iPhone (the same answer `WrittenMarginReader` gives at render time)

    private static func installedVoice(forLanguage code: String) -> String? {
        let wanted = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW"][code] ?? code
        if let voice = AVSpeechSynthesisVoice(language: wanted) { return voice.identifier }
        let base = wanted.split(separator: "-").first.map(String.init) ?? wanted
        return AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(base) }?.identifier
    }

    private static func defaultInstalledVoice() -> String? {
        AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier
    }
}
