import AVFoundation
import Foundation
import SessionKit

/// Plays the audio behind one sentence of a spoken note (#3108, #1609 slice 1): tap a sentence, hear it; tap it again
/// to stop. It plays only the sentence's own span of its own take and then stops. The span, and which file it is in,
/// are `SpokenNote.playback(for:)`; this type only drives the player and reports which sentence is sounding.
@MainActor
final class SpokenNotePlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing: SpokenNote.SentenceRef?
    @Published private(set) var message: String?

    private var player: AVAudioPlayer?
    private var span: SpokenNotePlayback?
    private var ticker: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    /// Plays the sentence, or stops it when it is the one sounding. `prepare` pauses whatever else the app is playing.
    func toggle(_ ref: SpokenNote.SentenceRef, in note: SpokenNote, folder: URL, prepare: () -> Void) {
        if playing == ref {
            stop()
            return
        }
        stop()
        message = nil
        guard let span = note.playback(for: ref), SpokenNoteIntake.isPlainFileName(span.audioFileName) else {
            message = "There is no audio behind this sentence."
            return
        }
        let url = folder.appendingPathComponent(span.audioFileName)
        prepare()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.currentTime = Double(span.startMs) / 1_000
            guard player.prepareToPlay(), player.play() else { throw CocoaError(.fileReadUnknown) }
            self.player = player
            self.span = span
            playing = ref
            startTicker()
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        } catch {
            message = "Couldn't play this audio. The recording is still on your phone."
            endSession()
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        span = nil
        if playing != nil { playing = nil }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        endSession()
    }

    private func endSession() {
        // Handed back to other apps; fails harmlessly while something else of ours is still using the session.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let player = self.player, let span = self.span else { return }
                if !player.isPlaying || span.hasEnded(atMs: Int(player.currentTime * 1_000)) {
                    self.stop()
                    return
                }
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.stop()
            self.message = "Couldn't play this audio. The recording is still on your phone."
        }
    }
}
