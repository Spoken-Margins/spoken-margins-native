import AVFoundation
import Combine
import Foundation
import SessionKit
import SessionKitAudio

extension Notification.Name {
    /// Posted by a share-review preview when it starts, so the card's other preview stops (#4171): the Listen control and
    /// "Hear it as your friend will" never play over each other. The object is the player that started.
    static let shareReviewPreviewDidStart = Notification.Name("SpokenMargins.shareReviewPreviewDidStart")
}

/// Plays "Hear it as your friend will" in the share review (#4171, PR 4b): the run-up from the episode, the two-note
/// chime the friend's player uses, then the Margin's chosen voice. A Margin that goes as words stops after the chime.
///
/// It owns its own players and never the main one: it writes no Now Playing info and registers no remote commands, so
/// the Lock Screen and a Live Activity stay with the main player. Removing the output (AirPods out) stops it. Where to
/// start is `SenderLeadInPreview.Plan`, the friend's own rule.
@MainActor
final class LeadInPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// The Margin whose preview is playing, if any.
    @Published private(set) var playingMarginID: String?
    /// The Margin whose last preview couldn't play, until the next start.
    @Published private(set) var failedMarginID: String?

    private enum Phase { case idle, runUp, chime, voice }
    private var phase = Phase.idle
    /// Bumped on every start and stop, so a callback from an earlier run does nothing.
    private var generation = 0
    private var episodePlayer: AVPlayer?
    private var boundaryObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var cuePlayer: AVAudioPlayer?
    private var voicePlayer: AVAudioPlayer?
    private var pendingVoiceURL: URL?
    /// Read only in `deinit`, which runs once no one else holds the player.
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    override init() {
        super.init()
        tokens.append(NotificationCenter.default.addObserver(
            forName: .shareReviewPreviewDidStart, object: nil, queue: .main
        ) { [weak self] note in
            let starter = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, starter != ObjectIdentifier(self) else { return }
                self.stop()
            }
        })
        #if os(iOS)
        tokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.stop() }
        })
        #endif
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    /// Starts the preview for one Margin. `episodeURL` nil (no download and no stream) shows the failure at once.
    func start(marginID: String, episodeURL: URL?, plan: SenderLeadInPreview.Plan, voiceURL: URL?) {
        stop()
        failedMarginID = nil
        guard let episodeURL else {
            failedMarginID = marginID
            return
        }
        // The app's playback session, as every other player sets it before it plays: without it a cold launch is still
        // in iOS's default mode, and the Ring/Silent switch mutes the whole preview with no failure shown (audit on #5108).
        do {
            try Self.activatePlaybackSession()
        } catch {
            failedMarginID = marginID
            return
        }
        NotificationCenter.default.post(name: .shareReviewPreviewDidStart, object: self)
        let run = generation
        playingMarginID = marginID
        pendingVoiceURL = voiceURL
        guard plan.runUpMs > 0 else {
            playChime(run)
            return
        }
        phase = .runUp
        let item = AVPlayerItem(url: episodeURL)
        let player = AVPlayer(playerItem: item)
        // Never on an AirPlay screen's Now Playing: this is a sample, not the listener's episode.
        player.allowsExternalPlayback = false
        episodePlayer = player
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.fail(run) }
        }
        // The output went away, or the system paused it: a stopped run-up is a stopped preview.
        timeControlObservation = player.observe(\.timeControlStatus, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue == .playing, change.newValue == .paused else { return }
            Task { @MainActor in
                MainThreadOperationLabels.shared.scoped("leadInPreview.runUpPaused") { self?.runUpWasPaused(run) }
            }
            // Reaching the end of this copy also pauses it; `runUpWasPaused` tells that apart from a stop.
        }
        let marginTime = CMTime(value: CMTimeValue(plan.marginMs), timescale: 1_000)
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: marginTime)], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.runUpEnded(run) }
        }
        // A Margin past the end of this copy: the run-up ends with the episode.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runUpEnded(run) }
        }
        let start = CMTime(value: CMTimeValue(plan.startMs), timescale: 1_000)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished, self.generation == run, self.phase == .runUp else { return }
                self.episodePlayer?.play()
            }
        }
    }

    /// The playback category (ducking other apps' audio, which a short sample shouldn't stop) and an active session.
    static func activatePlaybackSession() throws {
        #if os(iOS)
        try MainThreadOperationLabels.shared.scoped("shareReviewPreview.audioSession") {
            try PlaybackAudioSessionPolicy.ensurePlaybackCategory(options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        }
        #endif
    }

    func stop() {
        generation += 1
        tearDownEpisode()
        cuePlayer?.stop()
        cuePlayer = nil
        voicePlayer?.stop()
        voicePlayer = nil
        pendingVoiceURL = nil
        phase = .idle
        if playingMarginID != nil { playingMarginID = nil }
    }

    // MARK: Steps

    private func runUpEnded(_ run: Int) {
        guard generation == run, phase == .runUp else { return }
        tearDownEpisode()
        playChime(run)
    }

    private func runUpWasPaused(_ run: Int) {
        guard generation == run, phase == .runUp else { return }
        // A Margin past the end of this copy: the episode ran out, so the run-up is over, not stopped. This may arrive
        // before the end-of-item notification.
        if let item = episodePlayer?.currentItem, item.duration.isNumeric, item.currentTime() >= item.duration {
            runUpEnded(run)
            return
        }
        stop()
    }

    /// The sender changed what the preview would play: the old failure no longer says anything about it.
    func clearFailure(marginID: String) {
        if failedMarginID == marginID { failedMarginID = nil }
    }

    private func playChime(_ run: Int) {
        phase = .chime
        do {
            let cue = try SharedMarginChime.play()
            cue.delegate = self
            cuePlayer = cue
        } catch {
            // No chime is no reason to skip the Margin.
            playVoice(run)
        }
    }

    private func playVoice(_ run: Int) {
        guard generation == run else { return }
        cuePlayer = nil
        guard let url = pendingVoiceURL else {
            // Words only: the run-up and the chime, then it stops (Design §2).
            stop()
            return
        }
        phase = .voice
        do {
            let voice = try AVAudioPlayer(contentsOf: url)
            voice.delegate = self
            voice.prepareToPlay()
            guard voice.play() else { throw CocoaError(.fileReadUnknown) }
            voicePlayer = voice
        } catch {
            fail(run)
        }
    }

    private func fail(_ run: Int) {
        guard generation == run, let margin = playingMarginID else { return }
        stop()
        failedMarginID = margin
    }

    private func tearDownEpisode() {
        if let boundaryObserver { episodePlayer?.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        timeControlObservation = nil
        episodePlayer?.pause()
        episodePlayer = nil
    }

    // MARK: AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let cue = self.cuePlayer, ObjectIdentifier(cue) == finished, self.phase == .chime {
                MainThreadOperationLabels.shared.scoped("leadInPreview.voiceStart") { self.playVoice(self.generation) }
            } else if let voice = self.voicePlayer, ObjectIdentifier(voice) == finished {
                self.stop()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let failed = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let voice = self.voicePlayer, ObjectIdentifier(voice) == failed else { return }
            self.fail(self.generation)
        }
    }
}
