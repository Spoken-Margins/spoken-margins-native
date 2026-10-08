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

    private let source: Source
    private let voiceURL: (String) -> URL?
    private var lastObservedMs: Int?
    private var voice: AVAudioPlayer?
    private var voiceDelegate: VoiceDelegate?
    private var chime: AVAudioPlayer?
    /// Waiting out the chime. The Margin whose voice is loaded but not yet started, and the task that starts it.
    private var voiceAwaitingChime: (marginId: String, task: Task<Void, Never>)?

    public init(sequence: MarginMomentSequence, source: Source, voiceURL: @escaping (String) -> URL?) {
        self.sequence = sequence
        self.source = source
        self.voiceURL = voiceURL
    }

    /// A Margin's voice is loaded, playing or paused.
    public var isPlayingVoice: Bool { voice != nil }
    public private(set) var isVoicePaused = false
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
        lastObservedMs = sequence.startMediaTimeMs
        source.seek(sequence.startMediaTimeMs)
        onChange?()
    }

    /// Call on each progress tick while the source plays.
    public func observe(mediaTimeMs: Int?) {
        defer { if let mediaTimeMs { lastObservedMs = mediaTimeMs } }
        guard let margin = sequence.progressed(from: lastObservedMs, to: mediaTimeMs) else { return }
        source.pause()
        playVoice(for: margin)
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

    /// Ends the moment without resuming the source (another item, a recording, leaving playback).
    public func cancel() {
        stopVoice()
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
            let delegate = VoiceDelegate { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let voice = self.voice, ObjectIdentifier(voice) == playerID else { return }
                    self.finishVoice()
                }
            }
            player.delegate = delegate
            player.enableRate = true
            player.rate = min(2, max(0.5, voiceRate))
            player.volume = voiceVolume
            voice = player
            voiceDelegate = delegate
            if chimedMarginIds.contains(margin.marginId), let chimeSeconds = startChime(for: margin.marginId) {
                voiceAwaitingChime = (margin.marginId, startVoiceTask(after: chimeSeconds, playerID: playerID, marginId: margin.marginId))
            } else {
                beginVoice(player, marginId: margin.marginId)
            }
        } catch {
            onVoiceUnavailable?(margin.marginId, String(describing: error))
            finishVoice()
        }
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

    private func finishVoice() {
        stopVoice()
        sequence.marginFinished()
        onChange?()
        source.resume()
    }

    private func stopVoice() {
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

    private enum VoiceError: Error { case didNotStart }

    private final class VoiceDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        let finished: @Sendable () -> Void
        init(finished: @escaping @Sendable () -> Void) { self.finished = finished }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { finished() }
        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { finished() }
    }
}
#endif
