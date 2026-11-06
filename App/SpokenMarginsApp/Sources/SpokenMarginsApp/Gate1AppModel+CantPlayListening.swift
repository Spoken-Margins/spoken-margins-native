import AVFoundation
import Foundation
import SessionKit
import SessionKitAudio

/// A friend's episode that can't play (a private feed, a removed episode): the voice reads each Margin's quote, or its
/// place, and then the sender's Margin plays (owner, 2026-11-02, #3392). What is read, in what order, whether the
/// episode really failed and whether the listener still wants it after the wait is `CantPlayListening` (SessionKit,
/// host-tested). This file only reads the app's state into it and hands the steps to the one Margin-moment machine and
/// the one reader a written Margin already uses, so heard-marking, the chime, skip and interruptions are the ones every
/// friend Margin has. No resume flag and no second playback state machine.
extension Gate1AppModel {
    /// How long the first words get to render before the listening starts anyway. The words are short; a reading that
    /// still isn't there at its turn is passed over and the Margin plays at once (the conductor's missing-file path).
    private static let cantPlayRenderHold: TimeInterval = 6

    private var cantPlayScene: CantPlayListening.Scene {
        CantPlayListening.Scene(
            playerItemId: snapshot.itemId, selectedItemId: selectedItem.id, status: snapshot.status, isRecording: snapshot.isRecording,
            screen: String(describing: screen), hasMarginMoment: marginMomentConductor != nil
        )
    }

    /// The one trigger, called from `snapshotDidChange` on every snapshot change: this attempt to start the open podcast
    /// episode has just failed (`CantPlayListening.startFailed`), so a friend's new Margins are heard without it. The
    /// first tap on a dead episode gets the quote and then the Margin, with no second tap and no screen needed. The
    /// listening starts from here after the first words are rendered (at most `cantPlayRenderHold` seconds), unless the
    /// listener has moved on by then. Nothing is ended or paused until then.
    func hearFriendMarginsIfStartFailed(from old: SessionSnapshot) {
        let itemId = snapshot.itemId ?? ""
        guard old.status == .starting, snapshot.status == .failed, snapshot.itemId == old.itemId, selectedItem.id == itemId else { return }
        let entries = newSharedMargins(itemId: itemId)
        guard CantPlayListening.startFailed(
            from: .init(itemId: old.itemId, status: old.status, lastFailure: old.lastFailure),
            to: .init(itemId: snapshot.itemId, status: snapshot.status, lastFailure: snapshot.lastFailure),
            selectedItemId: selectedItem.id, isPodcastEpisode: selectedPodcastDownloadState != nil,
            hasPlayableFile: localEpisodeFile(for: itemId) != nil, friendMargins: entries.count
        ) else { return }
        let beats = CantPlayListening.plan(
            entries: entries, episodeTitle: selectedItem.title, voiceFor: Self.installedVoice(forLanguage:), defaultVoice: Self.defaultInstalledVoice
        )
        guard !beats.isEmpty, !rejectNavigationOrSessionMutationWhileRecording("hear_margins_without_episode") else { return }

        let reader = WrittenMarginReader.shared
        var readings: [String: WrittenMarginReading] = [:]
        for beat in beats { readings[beat.contextId] = beat.reading }
        var files = reader.start(readings) // the words, rendering now; their paths come from the words alone
        files.merge(WrittenMarginReadings.startingReview(for: beats.map(\.entry), voiceFile: resolvedApplicationSupportAssetURL(for:))) { words, _ in words }
        // The first words, and the first Margin's reading if it is a written one, are what the listening waits for.
        let first = [beats[0].reading] + (beats[0].entry.writtenReading.map { [$0] } ?? [])
        let began = cantPlayScene
        let place = snapshot.currentMediaTimeMs ?? 0
        Task { @MainActor [weak self] in
            await reader.waitUntilSettled(first, upTo: Self.cantPlayRenderHold)
            guard let self, CantPlayListening.stillWanted(itemId: itemId, began: began, now: self.cantPlayScene),
                  let sequence = CantPlayListening.sequence(for: beats, itemId: itemId, placeMs: place) else { return }
            self.startCantPlayListening(sequence: sequence, beats: beats, files: files)
        }
    }

    private func startCantPlayListening(sequence: MarginMomentSequence, beats: [CantPlayListening.Beat], files: [String: URL]) {
        // Only now that it will start does anything give way: a moment, an automatic prompt, a stalled start.
        endMarginMoment()
        importedCommentaryAutoPlayTask?.cancel()
        importedCommentaryAutoPlayTask = nil
        pendingImportedCommentary = nil
        _ = sharedMarginReturn.promptDismissed()
        stopImportedCommentaryPlayback(resumeSource: false)

        beats.forEach { sharedMarginOffers.markAnnounced($0.entry.interjection.id) } // the automatic prompts mustn't play them again
        var heard: [String: ImportedCommentaryInterjection] = [:]
        for beat in beats { heard[beat.marginId] = beat.entry.interjection }
        startMarginMoment(sequence: sequence, voiceURLs: files, title: "New Margins", isApproximate: false)
        guard let conductor = marginMomentConductor else { return }
        // Only a real Margin is ever marked heard, and only when its voice starts: the words have their own ids.
        conductor.onVoiceStarted = { [weak self] id in if let margin = heard[id] { self?.markSharedMarginHeard(margin) } }
        conductor.chimedMarginIds = Set(beats.filter { !$0.entry.layer.isMuted }.map(\.marginId))
        conductor.onChimeStarted = { [weak self] in self?.diagnostics["marginMoment.chime"] = "played:\($0)" }
        // Words that can't be read are passed over without a word: the Margin follows at once. A recording that can't
        // play says so.
        conductor.onVoiceUnavailable = { [weak self] id, reason in
            self?.diagnostics["marginMoment.voiceUnavailable"] = "\(id):\(reason)"
            guard let margin = heard[id], margin.audioPath != nil else { return }
            self?.reportWarning(SharedMarginAudio.unavailableWords(for: margin))
        }
        // A written Margin whose reading fails says what a written Margin's failure says, never "set not to be read".
        WrittenMarginReadings.rewordUnavailable(on: conductor, entries: beats.map(\.entry), model: self)
        diagnostics["marginMoment"] = "started:cant_play;beats=\(beats.count)"
        screen = .playback
        conductor.playTargetNow(movingSource: false) // no episode to move: the words start now, and nothing seeks the dead player
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
