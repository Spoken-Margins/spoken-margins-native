import AVFoundation
import Foundation
import SessionKit
import SessionKitAudio
import UIKit

/// A friend's episode that can't play (a private feed, a removed episode): the voice reads each Margin's quote, or its
/// place, and then the sender's Margin plays (owner, 2026-11-02, #3392). What is read, in what order, whether the
/// episode really failed and whether the listener still wants it after the wait is `CantPlayListening` (SessionKit,
/// host-tested). This file only reads the app's state into it and hands the steps to the one Margin-moment machine and
/// the one reader a written Margin already uses, so the chime, skip and interruptions are the ones every friend Margin
/// has. Heard-marking is not: by default a can't-play listening marks nothing heard (see `startCantPlayListening`). No resume flag and no second playback state machine.
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

    private func cantPlayAround(friendMargins: Int) -> CantPlayListening.Surroundings {
        CantPlayListening.Surroundings(
            selectedItemId: selectedItem.id, isPodcastEpisode: selectedPodcastDownloadState != nil,
            hasPlayableFile: localEpisodeFile(for: selectedItem.id) != nil, friendMargins: friendMargins,
            appIsActive: UIApplication.shared.applicationState == .active, onPlaybackScreen: screen == .playback
        )
    }

    /// The open item's Margins for a dead episode, by `SharedMarginReview.entriesWithoutEpisode` (a podcast that never
    /// downloaded has none placed). `asking`: the listener asked, so every layer counts; otherwise only auto-play ones.
    private func cantPlayEntries(asking: Bool) -> [SharedMarginReview.Entry] {
        SharedMarginReview.entriesWithoutEpisode(
            layers: selectedItem.importedCommentaryLayers, records: selectedItem.importedCommentaryInterjections,
            ownMargins: ownMargins(itemId: selectedItem.id), asking: asking
        ).filter { WrittenMarginReadings.audio(for: $0.interjection, in: $0.layer, voiceFile: resolvedApplicationSupportAssetURL(for:)).file != nil }
    }

    /// While the open podcast episode is dead (its start failed, no file on the phone), the Margins Review can offer:
    /// all of them, since a Review tap asks. Nil when it isn't dead, so every other item reads `entries` as before.
    func deadEpisodeEntries(itemId: String) -> [SharedMarginReview.Entry]? {
        guard snapshot.status == .failed, snapshot.itemId == itemId, selectedItem.id == itemId,
              CantPlayListening.isDeadEpisode(
                  .init(itemId: snapshot.itemId, status: snapshot.status, lastFailure: snapshot.lastFailure), cantPlayAround(friendMargins: 0)
              ) else { return nil }
        return cantPlayEntries(asking: true)
    }

    /// A Review tap on a dead episode: the listener asked, so every Margin is heard. True when this took the call.
    func reviewFriendMarginsOfDeadEpisode(itemId: String, entries: [SharedMarginReview.Entry]) -> Bool {
        guard deadEpisodeEntries(itemId: itemId) != nil else { return false }
        hearFriendMarginsWithoutEpisode(itemId: itemId, entries: entries, asking: true)
        return true
    }

    /// The one trigger for a listening nobody asked for, called from `snapshotDidChange` on every snapshot change: this
    /// attempt to start the open podcast episode has just failed (`CantPlayListening.startFailed`) with the app active
    /// and the listener on the playback screen, so the friend's auto-play Margins are heard without it. The first tap
    /// on a dead episode gets the quote and then the Margin, with no second tap. A Lock Screen or CarPlay Play gets the
    /// ordinary failure, and Margins set not to play by themselves wait for a Review tap.
    func hearFriendMarginsIfStartFailed(from old: SessionSnapshot) {
        guard old.status == .starting, snapshot.status == .failed, snapshot.itemId == old.itemId, selectedItem.id == snapshot.itemId else { return }
        let entries = cantPlayEntries(asking: false)
        guard CantPlayListening.startFailed(
            from: .init(itemId: old.itemId, status: old.status, lastFailure: old.lastFailure),
            to: .init(itemId: snapshot.itemId, status: snapshot.status, lastFailure: snapshot.lastFailure),
            around: cantPlayAround(friendMargins: entries.count)
        ) else { return }
        hearFriendMarginsWithoutEpisode(itemId: selectedItem.id, entries: entries, asking: false)
    }

    /// Reads the Margins' words and starts the listening after the first words are rendered (at most
    /// `cantPlayRenderHold` seconds), unless the listener has moved on by then. Nothing is ended or paused until then.
    private func hearFriendMarginsWithoutEpisode(itemId: String, entries: [SharedMarginReview.Entry], asking: Bool) {
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
            self.hangTelemetry.labels.scoped("cantPlayListening") {
                self.startCantPlayListening(sequence: sequence, beats: beats, files: files, asking: asking)
            }
        }
    }

    private func startCantPlayListening(sequence: MarginMomentSequence, beats: [CantPlayListening.Beat], files: [String: URL], asking: Bool) {
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
        // Default until the owner answers (#3392): nothing is marked heard. A start that timed out on a weak signal fails
        // the same way a removed episode does, and a Margin marked heard is gone from the listener's new Margins for good.
        // To mark Margins heard when their voice starts, set `conductor.onVoiceStarted` here to
        // `{ [weak self] id in if let margin = heard[id] { self?.markSharedMarginHeard(margin) } }`.
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
        if asking { screen = .playback } // a Review tap goes to the listening; a listening nobody asked for never moves the screen
        conductor.playTargetNow() // no episode to move: the conductor doesn't seek a can't-play listening, so the words start now
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
