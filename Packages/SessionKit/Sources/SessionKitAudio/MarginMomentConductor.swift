#if canImport(AVFoundation)
import AVFoundation
import Foundation
import SessionKit

/// Runs a `MarginMomentSequence` against real audio: pauses the source when a Margin is reached, plays the
/// Margin's saved voice, and resumes the source when the voice ends (#159).
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

    private let source: Source
    private let voiceURL: (String) -> URL?
    private var lastObservedMs: Int?
    private var voice: AVAudioPlayer?
    private var voiceDelegate: VoiceDelegate?

    public init(sequence: MarginMomentSequence, source: Source, voiceURL: @escaping (String) -> URL?) {
        self.sequence = sequence
        self.source = source
        self.voiceURL = voiceURL
    }

    /// A Margin's voice is loaded, playing or paused.
    public var isPlayingVoice: Bool { voice != nil }
    public private(set) var isVoicePaused = false

    /// Pause and play act on the Margin's voice while it has the floor; the source stays paused.
    public func setVoicePaused(_ paused: Bool) {
        guard let voice, paused != isVoicePaused else { return }
        if paused {
            voice.pause()
        } else {
            try? prepareAudioSession?()
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
            guard player.play() else { throw VoiceError.didNotStart }
            onVoiceStarted?(margin.marginId)
        } catch {
            onVoiceUnavailable?(margin.marginId, String(describing: error))
            finishVoice()
        }
    }

    private func finishVoice() {
        stopVoice()
        sequence.marginFinished()
        onChange?()
        source.resume()
    }

    private func stopVoice() {
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
