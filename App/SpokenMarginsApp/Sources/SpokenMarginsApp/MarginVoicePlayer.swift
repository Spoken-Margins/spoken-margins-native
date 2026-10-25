import AVFoundation
import Combine
import Foundation
import SessionKit
import SessionKitAudio

/// What the voice player asks of the model that owns it (#993). The player holds its host weakly and reads it at
/// callback time, so a poll in flight never keeps the model alive. None of these resumes the source on its own:
/// the one completion callback is the model's existing `stopImportedCommentaryPlayback(resumeSource: true)`, which
/// decides through `sharedMarginReturn`.
@MainActor
protocol MarginVoicePlayerHost: AnyObject {
    /// Read live when Now Playing is published: the setting can change while a voice plays.
    var marginVoiceMixesWithOtherAudio: Bool { get }
    /// Your own Margin played to its end.
    func marginVoiceOwnPlaybackEnded()
    /// Your own Margin's player failed.
    func marginVoiceOwnPlaybackFailed()
    /// A shared Margin's voice has played, so it is no longer new to the listener (#469).
    func marginVoiceSharedMarginHeard(_ margin: ImportedCommentaryInterjection)
    /// A shared Margin's voice played to its end.
    func marginVoiceSharedPlaybackEnded()
    /// Play, pause or toggle from the system's transport while a shared Margin plays.
    func marginVoiceRemoteCommand(_ command: CompactControlCommand)
}

/// The Margin voice transport (#993): the `AVPlayer` for your own Margin and for a shared Margin, the poll that
/// watches it, the shared Margin's chime and system transport, and the health record of a shared voice (#941).
/// Moved out of `Gate1AppModel` without changing a statement of what it does or the order it does it in.
///
/// It is dumb transport. It reads no model state, holds no store and no return claim, and starts nothing the
/// model did not ask for. The model composes its steps in the order the model always ran them, because several
/// model calls between two transport steps can re-enter (`pause()`, `pendingImportedCommentary = nil`).
///
/// The published values are the canonical copies; the model exposes them as computed projections and forwards
/// `objectWillChange` synchronously, so observers are told before a value changes, as they were when the model
/// published them itself. `health`, the player and the poll task are not published, as before.
@MainActor
final class MarginVoicePlayer: ObservableObject {
    /// The shared Margin whose voice is loaded, playing or paused.
    @Published private(set) var sharedMargin: ImportedCommentaryPrompt?
    @Published private(set) var sharedIsPaused = false
    /// What the shared Margin's voice is really doing (#941), judged from the player, not from the request to play.
    @Published private(set) var sharedPhase: SharedMarginPlaybackPhase = .loading
    @Published private(set) var ownMarginID: String?
    @Published private(set) var ownMarginSessionID: String?
    /// Your own Margin is loaded and held, not playing: the listener paused it, or recording a Margin over it holds it (#1672).
    @Published private(set) var ownIsPaused = false
    /// The Margins just saved over this one while it was held (#1672), by `marginIdentity`: they don't play next when this ends.
    var ownRecordedOverMarginIdentities: Set<String> = []
    /// The rate of the voice that is playing, 1 when none is.
    @Published private(set) var rate: Double = 1

    private(set) var health: SharedMarginPlaybackHealth?
    /// The one player, for your own Margin or a shared one. Internal and read-only so tests can watch the real player.
    private(set) var currentPlayer: AVPlayer?
    /// The poll that watches `currentPlayer`. Read-only for tests.
    private(set) var completionTask: Task<Void, Never>?
    private var cuePlayer: AVAudioPlayer?
    private let remoteControls = ImportedMarginRemoteControls()
    #if os(iOS)
    /// The options the voice's session was set up with, so a resume after a recording sets them again (#1672).
    private var sessionOptions: AVAudioSession.CategoryOptions = [.duckOthers]
    #endif
    /// A recording holds the voice and the system transport is the session's again: the poll mustn't publish over it (#1672).
    private var transportHandedBack = false
    private weak var host: (any MarginVoicePlayerHost)?

    init(host: any MarginVoicePlayerHost) {
        self.host = host
    }

    /// The model's `deinit` used to cancel the poll and nothing else; the cancel moves here, with the same limits.
    /// It must never stop the player, touch the audio session or resume anything.
    deinit {
        completionTask?.cancel()
    }

    func isPlayingOwn(_ interjection: Interjection) -> Bool {
        ownMarginID == interjection.id && ownMarginSessionID == interjection.sessionId
    }

    // MARK: Your own Margin

    /// Starts your own Margin's voice. `url` is called after the audio session is configured, so a session error
    /// leaves no leveling diagnostics and starts no leveling work, as it did when the model made the URL inline.
    func startOwn(_ interjection: Interjection, url: () -> URL, rate: Double) throws {
        #if os(iOS)
        try PlaybackAudioSessionPolicy.ensurePlaybackCategory(options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        sessionOptions = [.duckOthers]
        #endif
        let item = AVPlayerItem(url: url())
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.defaultRate = Float(rate)
        currentPlayer = player
        ownMarginID = interjection.id
        ownMarginSessionID = interjection.sessionId
        ownIsPaused = false
        ownRecordedOverMarginIdentities = []
        self.rate = rate
        completionTask = Task { @MainActor [weak self, weak item] in
            while !Task.isCancelled, let item {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if item.status == .failed {
                    self?.host?.marginVoiceOwnPlaybackFailed()
                    return
                }
                let reading = MarginVoiceClockReading(duration: item.duration.seconds, current: item.currentTime().seconds)
                if reading.hasReachedEnd {
                    self?.host?.marginVoiceOwnPlaybackEnded()
                    return
                }
            }
        }
        player.playImmediately(atRate: Float(rate))
    }

    /// Pauses your own Margin's voice where it is, or plays it on from there (#1672). The poll keeps watching the
    /// player, and a paused player is not at its end, so the Margin neither ends nor restarts. A throw while resuming
    /// leaves it paused.
    func setOwnPaused(_ paused: Bool) throws {
        guard ownMarginID != nil, let player = currentPlayer else { return }
        if paused {
            player.pause()
        } else {
            #if os(iOS)
            // A recording over the voice changed the category; the voice plays in its own again.
            try PlaybackAudioSessionPolicy.ensurePlaybackCategory(options: sessionOptions)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            player.playImmediately(atRate: Float(rate))
        }
        ownIsPaused = paused
    }

    // MARK: A shared Margin

    /// Loads a shared Margin's voice and publishes it: session, item, player, volume, rate, then the prompt, the
    /// paused flag and a fresh health record. Everything that can throw is the two session calls, before anything is
    /// published. The model then clears the card and hands over system transport, and calls `beginShared`.
    func prepareShared(
        _ prompt: ImportedCommentaryPrompt,
        url: () -> URL,
        rate: Double,
        mixesWithOtherAudio: Bool,
        lowersBackgroundAudio: Bool,
        mixedPlaybackVolume: Double
    ) throws {
        #if os(iOS)
        let options = PlaybackAudioSessionPolicy.options(mixes: mixesWithOtherAudio, lowersBackground: lowersBackgroundAudio)
        try PlaybackAudioSessionPolicy.ensurePlaybackCategory(options: options)
        try AVAudioSession.sharedInstance().setActive(true)
        sessionOptions = options
        #endif
        transportHandedBack = false
        let item = AVPlayerItem(url: url())
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.volume = mixesWithOtherAudio ? Float(mixedPlaybackVolume) : 1
        player.defaultRate = Float(rate)
        currentPlayer = player
        self.rate = rate
        sharedMargin = prompt
        sharedIsPaused = false
        let startedHealth = SharedMarginPlaybackHealth(startedAt: ProcessInfo.processInfo.systemUptime)
        health = startedHealth
        sharedPhase = startedHealth.phase
    }

    /// Installs the system transport when asked, starts the poll and asks the player to play. Last, in that order.
    func beginShared(installRemoteControls: Bool) {
        guard let player = currentPlayer, let item = player.currentItem,
              let prompt = sharedMargin, let attempt = health?.attemptID else { return }
        if installRemoteControls {
            remoteControls.install { [weak self] command in
                guard let self, self.sharedMargin != nil else { return }
                self.host?.marginVoiceRemoteCommand(command)
            }
        }
        completionTask = Task { @MainActor [weak self, weak item, weak player] in
            var heard = false
            while !Task.isCancelled, let item {
                try? await Task.sleep(for: .milliseconds(200))
                // A reading from a replaced or retried attempt must not touch the current one. The task is
                // cancelled first on every ordinary path, so only a test reaches this guard's return.
                guard !Task.isCancelled, let self, self.health?.attemptID == attempt else { return }
                let reading = MarginVoiceClockReading(duration: item.duration.seconds, current: item.currentTime().seconds)
                // Heard once the voice has played; a file that fails to decode stays new (#690).
                if !heard, reading.hasSounded { heard = true; self.host?.marginVoiceSharedMarginHeard(prompt.interjection) }
                if reading.hasReachedEnd {
                    self.host?.marginVoiceSharedPlaybackEnded()
                    return
                }
                let failed = item.status == .failed || player?.status == .failed
                self.observe(playerFailed: failed, clockSeconds: reading.current, playerAtRest: player?.timeControlStatus == .paused)
                if self.sharedPhase.isFailed { return }
                self.publishNowPlaying()
            }
        }
        player.playImmediately(atRate: Float(rate))
    }

    /// The system transport goes back to a shared voice that a recording was holding (#1672); `beginShared` installed it first.
    func installSharedRemoteControls() {
        guard sharedMargin != nil else { return }
        transportHandedBack = false
        remoteControls.install { [weak self] command in
            guard let self, self.sharedMargin != nil else { return }
            self.host?.marginVoiceRemoteCommand(command)
        }
    }

    /// Pauses or resumes the shared voice and records it: the paused flag, the health record and the phase are
    /// separate writes, and a throw while resuming leaves all of them as they were.
    func setSharedPaused(_ paused: Bool) throws {
        guard let player = currentPlayer else { return }
        if paused {
            player.pause()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        } else {
            #if os(iOS)
            // A recording over the voice (#1672) changed the category; the voice plays in its own again.
            try PlaybackAudioSessionPolicy.ensurePlaybackCategory(options: sessionOptions)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            player.playImmediately(atRate: Float(rate))
        }
        sharedIsPaused = paused
        health?.setUserPaused(paused, at: ProcessInfo.processInfo.systemUptime)
        if let phase = health?.phase { sharedPhase = phase }
        publishNowPlaying()
    }

    /// Feeds the player's own report into the health rule and shows what it concludes (#941).
    private func observe(playerFailed: Bool, clockSeconds: Double, playerAtRest: Bool) {
        guard var current = health else { return }
        let phase = current.observe(playerFailed: playerFailed, clockSeconds: clockSeconds, playerAtRest: playerAtRest, at: ProcessInfo.processInfo.systemUptime)
        health = current
        if phase != sharedPhase { sharedPhase = phase }
        if phase.isFailed { failSharedPlayback() }
    }

    /// The voice cannot play. Stops the player and the polling, keeps the Margin on screen with Retry and
    /// Return to Source, and tells the system it is not playing. The Margin stays new; the source-resume
    /// intent is untouched, so Return to Source or a Retry that then ends still resumes it once.
    private func failSharedPlayback() {
        completionTask?.cancel()
        completionTask = nil
        currentPlayer?.pause()
        currentPlayer?.replaceCurrentItem(with: nil)
        currentPlayer = nil
        sharedIsPaused = false
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        guard let host, !host.marginVoiceMixesWithOtherAudio, !transportHandedBack, let prompt = sharedMargin else { return }
        let player = currentPlayer
        remoteControls.publish(
            sender: prompt.senderLabel, elapsed: player?.currentTime().seconds ?? 0,
            duration: player?.currentItem?.duration.seconds ?? .nan,
            rate: health?.nowPlayingRate(playerRate: Double(player?.rate ?? 0)) ?? 0
        )
    }

    // MARK: Stopping, in the steps the model composes

    /// First step of a stop: the shared Margin's published state goes, in the order it always went.
    func resetSharedState() {
        sharedMargin = nil
        sharedIsPaused = false
        health = nil
        sharedPhase = .loading
    }

    func endRemoteControls() {
        transportHandedBack = true
        remoteControls.end()
    }

    /// Last step of a stop: the player, the poll and your own Margin's published state.
    func releasePlayer() {
        currentPlayer?.pause()
        currentPlayer?.replaceCurrentItem(with: nil)
        currentPlayer = nil
        completionTask?.cancel()
        completionTask = nil
        ownMarginID = nil
        ownMarginSessionID = nil
        ownIsPaused = false
        ownRecordedOverMarginIdentities = []
        rate = 1
    }

    /// The second, redundant clear `stopImportedCommentaryPlayback` has always made (R16). It still fires one more
    /// notification, so it stays until a change says why it may go.
    func forgetSharedMargin() {
        sharedMargin = nil
    }

    // MARK: The chime

    func playCue() throws {
        cuePlayer = try SharedMarginChime.play()
    }
}
