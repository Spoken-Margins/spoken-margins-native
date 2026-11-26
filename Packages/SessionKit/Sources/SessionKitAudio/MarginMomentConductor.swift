#if canImport(AVFoundation)
import AVFoundation
import Foundation
import SessionKit

/// Runs a `MarginMomentSequence` against real audio: pauses the source when a Margin is reached, plays the
/// Margin's saved voice, and resumes the source when the voice ends (#159).
///
/// Another listener's Margins (`chimedMarginIds`) get the shared-Margin chime first, so their voice never
/// starts unannounced (#932).
///
/// A review of new shared Margins (#474) runs through here too: when a voice ends, the sequence says whether the
/// source plays on, plays the next Margin straight away, or (after the last one, for a listener who was further on)
/// goes back to where the listener left off. It never hops ahead by itself.
///
/// The app owns the source transport and supplies it as closures; this type owns only the Margin voice.
@MainActor
public final class MarginMomentConductor {
    public struct Source {
        public var pause: @MainActor () -> Void
        public var resume: @MainActor () -> Void
        public var seek: @MainActor (_ mediaTimeMs: Int) -> Void

        public init(
            pause: @escaping @MainActor () -> Void,
            resume: @escaping @MainActor () -> Void,
            seek: @escaping @MainActor (_ mediaTimeMs: Int) -> Void
        ) {
            self.pause = pause
            self.resume = resume
            self.seek = seek
        }
    }

    public private(set) var sequence: MarginMomentSequence
    /// Called whenever `sequence` changes, so the UI can refresh.
    public var onChange: (@MainActor () -> Void)?
    /// Called when a Margin's voice can't be played; the source continues without it.
    public var onVoiceUnavailable: (@MainActor (_ marginId: String, _ reason: String) -> Void)?
    /// Called once a Margin's voice has started playing (#469: a shared Margin is no longer new).
    public var onVoiceStarted: (@MainActor (_ marginId: String) -> Void)?
    /// Called when a Margin's voice stops for any reason but `cancel()` or `stopReview()` (#4711). `reachedEnd` is true
    /// only when the recording played to its end; a skip, a decode error, a missing file and a voice that would not
    /// start report false. The conductor doesn't know whose Margin it played.
    public var onVoiceEnded: (@MainActor (_ margin: MarginMomentAnchor, _ reachedEnd: Bool) -> Void)?
    /// Called before a voice starts, to configure the audio session (iOS).
    public var prepareAudioSession: (@MainActor () throws -> Void)?
    public var voiceRate: Float = 1
    public var voiceVolume: Float = 1
    /// Margins that get the shared-Margin chime before their voice (#932): another listener's, never your own.
    /// The app leaves a Margin out when its layer is muted. Empty means no chime.
    public var chimedMarginIds: Set<String> = []
    public var chimeVolume: Float = SharedMarginChime.defaultVolume
    /// Called when the chime starts playing, just before that Margin's voice (#932).
    public var onChimeStarted: (@MainActor (_ marginId: String) -> Void)?
    /// Silence between the end of the chime and the start of the voice, matching the inline prompt's pause.
    static let pauseAfterChimeSeconds = 0.15

    private let givenSource: Source
    private let voiceURL: (String) -> URL?
    private var lastObservedMs: Int?
    private var voice: AVAudioPlayer?
    private var voiceDelegate: VoiceDelegate?
    private var chime: AVAudioPlayer?
    #if os(iOS)
    private var audioSessionObservers: [NSObjectProtocol] = []
    #endif
    /// Waiting out the chime. The Margin whose voice is loaded but not yet started, and the task that starts it.
    private var voiceAwaitingChime: (marginId: String, task: Task<Void, Never>)?

    public init(sequence: MarginMomentSequence, source: Source, voiceURL: @escaping (String) -> URL?) {
        self.sequence = sequence
        self.givenSource = source
        self.voiceURL = voiceURL
    }

    /// A Margin's voice is loaded, playing or paused.
    public var isPlayingVoice: Bool { voice != nil }
    public private(set) var isVoicePaused = false
    /// How far through the sounding voice is, for the pinned card (#3220). Nil while no voice has the floor.
    public var voiceReading: MarginVoiceClockReading? {
        voice.map { MarginVoiceClockReading(duration: $0.duration, current: $0.currentTime) }
    }
    /// The shared-Margin chime is sounding (#932).
    public var isPlayingChime: Bool { chime?.isPlaying == true }

    /// Pause and play act on the Margin's voice while it has the floor; the source stays paused.
    public func setVoicePaused(_ paused: Bool) {
        guard let voice, paused != isVoicePaused else { return }
        if paused {
            voice.pause()
            // Paused during the chime: the voice hasn't started, so cut the chime too. Resume starts the voice.
            chime?.stop()
            chime = nil
        } else {
            try? prepareAudioSession?()
            if let waiting = voiceAwaitingChime {
                // Paused during the chime: the voice hasn't started yet, so resuming is its first start.
                waiting.task.cancel()
                voiceAwaitingChime = nil
                isVoicePaused = false
                beginVoice(voice, marginId: waiting.marginId)
                onChange?()
                return
            }
            guard voice.play() else { return finishVoice() }
        }
        isVoicePaused = paused
        onChange?()
    }

    /// Starts the lead-in: seeks the source to the sequence's start.
    public func start() {
        source.seek(sequence.startMediaTimeMs)
        // After the seek: the app tells `sourceMoved()` about every seek, which would clear this baseline (#1646).
        lastObservedMs = sequence.startMediaTimeMs
        onChange?()
    }

    /// Starts a sequence that is already listening (#1538): the source is where the listener left it, so nothing seeks.
    public func startListening(atMediaTimeMs mediaTimeMs: Int?) {
        lastObservedMs = mediaTimeMs ?? sequence.startMediaTimeMs
        onChange?()
    }

    /// The listener skipped or sought the source themselves (#1646). The next reading is a new place, not playback
    /// reaching it, so it crosses nothing: skipping over a Margin doesn't play it, however short the skip.
    public func sourceMoved() {
        lastObservedMs = nil
    }

    /// Call on each progress tick while the source plays.
    public func observe(mediaTimeMs: Int?) {
        defer { if let mediaTimeMs { lastObservedMs = mediaTimeMs } }
        guard let margin = sequence.progressed(from: lastObservedMs, to: mediaTimeMs) else { return }
        source.pause()
        playVoice(for: margin)
    }

    /// The source, as everything below reaches it. A listening for an episode that can't play has none: a seek would
    /// only wake the dead player and fail, and a pause would report "Paused." and turn its failure into a pause (#3392).
    /// One rule here, so no way of moving, pausing or resuming can miss it.
    private var source: Source {
        CantPlayListening.isCantPlayListening(sequence) ? Source(pause: {}, resume: {}, seek: { _ in }) : givenSource
    }

    /// "Play it now" during the lead-in.
    public func playTargetNow() {
        guard let margin = sequence.jumpToTarget() else { return }
        source.pause()
        source.seek(margin.mediaTimeMs)
        lastObservedMs = margin.mediaTimeMs
        playVoice(for: margin)
    }

    /// Stops the current Margin's voice and continues the source.
    public func skipVoice() {
        guard sequence.isPlayingMargin else { return }
        finishVoice()
    }

    /// "Start a minute earlier" (#4171): plays `plan`'s Margin again after its longer run-up. A sounding voice (or its chime)
    /// stops without counting as finished, so a review does not move on and keeps its count; the source goes back to the
    /// run-up's start and, if a voice had paused it, plays again. During a run-up the source is already playing and only
    /// moves. Does nothing when the plan is for neither the Margin playing nor the target in its run-up.
    public func restartLonger(_ plan: StartEarlier.Plan) {
        let voiceHeldTheSource = sequence.isPlayingMargin
        guard let start = sequence.restartLonger(marginId: plan.marginId, leadInMs: plan.leadInMs) else { return }
        stopVoice()
        source.seek(start)
        // After the seek, as in `start()`: the app tells `sourceMoved()` about every seek, which would clear this baseline.
        lastObservedMs = start
        onChange?()
        if voiceHeldTheSource { source.resume() }
    }

    /// Ends the moment without resuming the source (another item, a recording, leaving playback).
    public func cancel() {
        stopVoice()
        onChange = nil
    }

    /// The listener stopped a review: the voice stops and the source stays paused. It goes back to where they left off
    /// only to undo the review's own hop, or to bring back a listener who was further on (`placeToReturnToWhenStopped`).
    public func stopReview() {
        guard sequence.review != nil else { return cancel() }
        stopVoice()
        source.pause()
        let at = lastObservedMs ?? sequence.playing?.mediaTimeMs ?? sequence.target.mediaTimeMs
        if let place = sequence.placeToReturnToWhenStopped(sourceAtMediaTimeMs: at) { moveSource(to: place) }
        onChange = nil
    }

    private func playVoice(for margin: MarginMomentAnchor) {
        onChange?()
        guard let url = voiceURL(margin.marginId), FileManager.default.fileExists(atPath: url.path) else {
            onVoiceUnavailable?(margin.marginId, "recording_missing")
            finishVoice()
            return
        }
        do {
            try prepareAudioSession?()
            let player = try AVAudioPlayer(contentsOf: url)
            let playerID = ObjectIdentifier(player)
            let delegate = VoiceDelegate { [weak self] reachedEnd in
                Task { @MainActor [weak self] in
                    guard let self, let voice = self.voice, ObjectIdentifier(voice) == playerID else { return }
                    // Named for the hang probe (#2255): finishing resumes the source or starts the next voice.
                    let labels = MainThreadOperationLabels.shared
                    labels.scoped("marginMomentVoiceFinished") { self.finishVoice(reachedEnd: reachedEnd) }
                }
            }
            player.delegate = delegate
            player.enableRate = true
            player.rate = min(2, max(0.5, voiceRate))
            player.volume = voiceVolume
            voice = player
            voiceDelegate = delegate
            holdVoiceWhenAudioIsLost()
            if chimedMarginIds.contains(margin.marginId), let chimeSeconds = startChime(for: margin.marginId) {
                voiceAwaitingChime = (margin.marginId, startVoiceTask(after: chimeSeconds, playerID: playerID, marginId: margin.marginId))
            } else {
                beginVoice(player, marginId: margin.marginId)
            }
        } catch {
            onVoiceUnavailable?(margin.marginId, SafeErrorText.describe(error))
            finishVoice()
        }
    }

    /// Headphones unplugged, a Bluetooth route lost or a call coming in: hold the voice, like every other player
    /// in the app, so a friend's voice never starts, or carries on, without a Play (#932 audit). An interrupted
    /// voice that is waiting for its chime would otherwise be refused by the system and lost as unplayable.
    private func holdVoiceWhenAudioIsLost() {
        #if os(iOS)
        guard audioSessionObservers.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        audioSessionObservers = [
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                Task { @MainActor [weak self] in self?.setVoicePaused(true) }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                Task { @MainActor [weak self] in self?.setVoicePaused(true) }
            }
        ]
        #endif
    }

    /// Starts the voice, or gives up on it like any voice that can't play.
    private func beginVoice(_ player: AVAudioPlayer, marginId: String) {
        guard player.play() else {
            onVoiceUnavailable?(marginId, String(describing: VoiceError.didNotStart))
            return finishVoice()
        }
        onVoiceStarted?(marginId)
    }

    /// Plays the shared-Margin chime and returns how long it runs. A chime that can't play is skipped: the
    /// voice matters more than the cue.
    private func startChime(for marginId: String) -> TimeInterval? {
        guard let player = try? SharedMarginChime.play(volume: chimeVolume), player.isPlaying else { return nil }
        chime = player
        onChimeStarted?(marginId)
        return player.duration
    }

    /// Starts the loaded voice once the chime and the short pause after it are over, unless the Margin was
    /// skipped, cancelled or paused meanwhile.
    private func startVoiceTask(after chimeSeconds: TimeInterval, playerID: ObjectIdentifier, marginId: String) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(chimeSeconds + Self.pauseAfterChimeSeconds))
            guard !Task.isCancelled, let self, let voice = self.voice, ObjectIdentifier(voice) == playerID,
                  !self.isVoicePaused else { return }
            self.voiceAwaitingChime = nil
            self.chime = nil
            self.beginVoice(voice, marginId: marginId)
        }
    }

    private func finishVoice(reachedEnd: Bool = false) {
        let ended = sequence.playing
        stopVoice()
        if let ended { onVoiceEnded?(ended, reachedEnd) }
        let advance = sequence.marginFinished(sourceAtMediaTimeMs: lastObservedMs)
        onChange?()
        switch advance {
        case .continueSource:
            source.resume()
        case .playNow(let margin):
            playVoice(for: margin)
        case .reviewDone(let returnTo, let resumes):
            if let returnTo { moveSource(to: returnTo) }
            if resumes { source.resume() }
        }
    }

    /// Moves the source, and the place the next progress tick is measured from, so the jump isn't read as playback.
    private func moveSource(to mediaTimeMs: Int) {
        lastObservedMs = mediaTimeMs
        source.seek(mediaTimeMs)
    }

    private func stopVoice() {
        #if os(iOS)
        for observer in audioSessionObservers { NotificationCenter.default.removeObserver(observer) }
        audioSessionObservers = []
        #endif
        voiceAwaitingChime?.task.cancel()
        voiceAwaitingChime = nil
        chime?.stop()
        chime = nil
        voice?.stop()
        voice?.delegate = nil
        voice = nil
        voiceDelegate = nil
        isVoicePaused = false
    }

    /// Test seam (#4711): hands the playing voice's delegate the finish the system would, with the given flag, since a
    /// real player can't be made to report an unsuccessful finish on demand.
    func deliverVoiceFinishForTesting(successfully: Bool) {
        guard let voice, let voiceDelegate else { return }
        voiceDelegate.audioPlayerDidFinishPlaying(voice, successfully: successfully)
    }

    private enum VoiceError: Error { case didNotStart }

    private final class VoiceDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        let finished: @Sendable (_ reachedEnd: Bool) -> Void
        init(finished: @escaping @Sendable (_ reachedEnd: Bool) -> Void) { self.finished = finished }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { finished(flag) }
        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { finished(false) }
    }
}
#endif
