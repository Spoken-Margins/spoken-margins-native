import AVFoundation
import Foundation

/// The audio session and the player behind "Hear my recording" on a live session's Margin. An actor, so finding the
/// file, activating the session and opening the file never run on the main thread (the main-thread-reads ratchet,
/// #2257), and a start and an end run in the order they were asked for.
actor LiveSessionMarginAudioPlayer {
    static let shared = LiveSessionMarginAudioPlayer()

    /// A player that has begun playing. The model reads only its state afterwards.
    struct Started: @unchecked Sendable {
        let player: AVAudioPlayer
    }

    func start(audioPath: String) throws -> Started {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let url = Gate1AppModel.resolvedInterjectionAudioURL(for: audioPath, applicationSupportDirectory: support) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.prepareToPlay(), player.play() else { throw CocoaError(.fileReadUnknown) }
        return Started(player: player)
    }

    /// Hands the session back to other apps. Fails harmlessly while something else of ours is still using it.
    func end() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Plays a spoken Margin's own recording from a live session: tap to hear it, tap again to stop. It stops when the
/// recording ends, when the screen goes away, or when something else interrupts the audio.
@MainActor
final class LiveSessionMarginAudioModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var message: String?

    private var player: AVAudioPlayer?
    private var starting: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    /// Rises with every tap and every stop, so a player that finishes starting after the listener moved on is dropped.
    private var generation = 0
    /// We have started, or are starting, the audio session, so it must be handed back when we stop.
    private var holdsSession = false

    /// Plays the recording, or stops it when it is playing. `prepare` pauses whatever else the app is playing.
    func toggle(audioPath: String, prepare: () -> Void) {
        if isPlaying {
            stop()
            return
        }
        stop()
        message = nil
        prepare()
        let mine = generation
        holdsSession = true
        isPlaying = true // shows at once; the audio follows
        starting = Task { [weak self] in
            do {
                let started = try await LiveSessionMarginAudioPlayer.shared.start(audioPath: audioPath)
                self?.begin(started.player, generation: mine)
            } catch {
                self?.failed(generation: mine)
            }
        }
    }

    func stop() {
        if tearDown() { Task { await LiveSessionMarginAudioPlayer.shared.end() } }
    }

    /// Everything that is ours to stop on the main thread. Returns whether the audio session must be handed back.
    private func tearDown() -> Bool {
        generation += 1
        starting?.cancel()
        starting = nil
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        if isPlaying { isPlaying = false }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        defer { holdsSession = false }
        return holdsSession
    }

    private func begin(_ player: AVAudioPlayer, generation started: Int) {
        guard started == generation else {
            // The listener tapped again or left while it was starting.
            player.stop()
            return
        }
        self.player = player
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let player = self.player else { return }
                if !player.isPlaying {
                    self.stop()
                    return
                }
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    private func failed(generation started: Int) {
        guard started == generation else { return }
        stop()
        message = "Couldn't play this recording. It is still on your phone."
    }
}
