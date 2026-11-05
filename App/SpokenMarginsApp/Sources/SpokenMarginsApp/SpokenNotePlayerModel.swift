import AVFoundation
import Foundation
import SessionKit

/// The audio session and the player behind a spoken note's sentences. An actor, so activating the session and opening
/// the file never run on the main thread (the main-thread-reads ratchet, #2257), and a start and an end run in the
/// order they were asked for.
actor SpokenNoteSentenceAudio {
    static let shared = SpokenNoteSentenceAudio()

    /// A player that has begun playing. The model reads only its position afterwards.
    struct Started: @unchecked Sendable {
        let player: AVAudioPlayer
    }

    func start(url: URL, startMs: Int) throws -> Started {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let player = try AVAudioPlayer(contentsOf: url)
        player.currentTime = Double(startMs) / 1_000
        guard player.prepareToPlay(), player.play() else { throw CocoaError(.fileReadUnknown) }
        return Started(player: player)
    }

    /// Hands the session back to other apps. Fails harmlessly while something else of ours is still using it.
    func end() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Plays the audio behind one sentence of a spoken note (#3108, #1609 slice 1): tap a sentence, hear it; tap it again
/// to stop. It plays only the sentence's own span of its own take and then stops. The span, and which file it is in,
/// are `SpokenNote.playback(for:)`; this type only drives the player and reports which sentence is sounding.
@MainActor
final class SpokenNotePlayerModel: ObservableObject {
    @Published private(set) var playing: SpokenNote.SentenceRef?
    @Published private(set) var message: String?

    private var player: AVAudioPlayer?
    private var starting: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    /// Rises with every tap and every stop, so a player that finishes starting after the listener moved on is dropped.
    private var generation = 0

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
        let mine = generation
        playing = ref // shows at once; the audio follows
        starting = Task { [weak self] in
            do {
                let started = try await SpokenNoteSentenceAudio.shared.start(url: url, startMs: span.startMs)
                self?.begin(started.player, span: span, generation: mine)
            } catch {
                self?.failed(generation: mine)
            }
        }
    }

    func stop() {
        generation += 1
        starting?.cancel()
        starting = nil
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        if playing != nil { playing = nil }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        Task { await SpokenNoteSentenceAudio.shared.end() }
    }

    private func begin(_ player: AVAudioPlayer, span: SpokenNotePlayback, generation started: Int) {
        guard started == generation else {
            // The listener tapped again or left while it was starting.
            player.stop()
            return
        }
        self.player = player
        startTicker(span)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    private func failed(generation started: Int) {
        guard started == generation else { return }
        stop()
        message = "Couldn't play this audio. The recording is still on your phone."
    }

    /// Stops at the end of the sentence (or of the file), checked every 20 ms so a sentence doesn't run into the next.
    private func startTicker(_ span: SpokenNotePlayback) {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard let self, let player = self.player else { return }
                if !player.isPlaying || span.hasEnded(atMs: Int(player.currentTime * 1_000)) {
                    self.stop()
                    return
                }
            }
        }
    }
}
