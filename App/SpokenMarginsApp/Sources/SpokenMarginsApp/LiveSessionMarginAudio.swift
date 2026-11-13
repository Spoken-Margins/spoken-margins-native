import AVFoundation
import Foundation

/// The audio session and the player behind "Hear my recording" on a live session's Margin. An actor, so finding the
/// file, activating the session and opening the file never run on the main thread (the main-thread-reads ratchet,
/// #2257), and a start and an end run in the order they were asked for.
actor LiveSessionMarginAudioPlayer {
    static let shared = LiveSessionMarginAudioPlayer()

    /// Hands the session back to other apps. Fails harmlessly while something else of ours is still using it.
    private let deactivate: @Sendable () -> Void
    /// The player this actor started and has not yet stopped, with the model's generation it was asked for. The actor
    /// stops it itself, in `end`, so the hand-back can never run while it is still playing (#3649).
    private var current: (player: AVAudioPlayer, generation: Int)?

    init(deactivate: @escaping @Sendable () -> Void = {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }) {
        self.deactivate = deactivate
    }

    /// A player that has begun playing. The model reads only its state afterwards.
    struct Started: @unchecked Sendable {
        let player: AVAudioPlayer
    }

    func start(audioPath: String, generation: Int = 0) throws -> Started {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let url = Gate1AppModel.resolvedInterjectionAudioURL(for: audioPath, applicationSupportDirectory: support) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try start(url: url, generation: generation)
    }

    func start(url: URL, generation: Int = 0) throws -> Started {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        current?.player.stop()
        current = nil
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.prepareToPlay(), player.play() else { throw CocoaError(.fileReadUnknown) }
        current = (player, generation)
        return Started(player: player)
    }

    /// Stops the player, then hands the session back. The actor is serial, so a start still in flight finishes first
    /// and its player is stopped here too. Deactivating while a player runs fails, and the session would stay active
    /// as `.playback` with other apps' audio unable to resume.
    ///
    /// `generation` is the model's generation at the stop. A player started for that generation or a later one belongs
    /// to a Margin the listener tapped after this stop, and a stop whose task reached the actor late must not kill it,
    /// so it is left playing and the session stays with it.
    func end(generation: Int = .max) {
        if let current {
            guard current.generation < generation else { return }
            current.player.stop()
        }
        current = nil
        deactivate()
    }
}

/// Plays a spoken Margin's own recording from a live session: tap to hear it, tap again to stop. It stops when the
/// recording ends, when the screen goes away, or when something else interrupts the audio.
@MainActor
final class LiveSessionMarginAudioModel: ObservableObject {
    /// The Margin whose recording is playing or starting. One model serves a whole pane, so a tap on another Margin
    /// stops this one and starts that one, and only the playing row says "Stop playing".
    @Published private(set) var playingId: String?
    var isPlaying: Bool { playingId != nil }
    @Published private(set) var message: String?

    private var player: AVAudioPlayer?
    private var starting: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    /// Rises with every tap and every stop, so a player that finishes starting after the listener moved on is dropped.
    private var generation = 0
    /// We have started, or are starting, the audio session, so it must be handed back when we stop.
    private var holdsSession = false

    /// Plays the recording, or stops it when this Margin's is the one playing. A tap on a different Margin stops the
    /// one playing and plays that one. `prepare` pauses whatever else the app is playing.
    func toggle(id: String = "", audioPath: String, prepare: () -> Void) {
        if playingId == id {
            stop()
            return
        }
        stop()
        message = nil
        prepare()
        let mine = generation
        holdsSession = true
        playingId = id // shows at once; the audio follows
        starting = Task { [weak self] in
            do {
                let started = try await LiveSessionMarginAudioPlayer.shared.start(audioPath: audioPath, generation: mine)
                self?.begin(started.player, generation: mine)
            } catch {
                self?.failed(generation: mine)
            }
        }
    }

    func stop() {
        if let stopped = tearDown() { Task { await LiveSessionMarginAudioPlayer.shared.end(generation: stopped) } }
    }

    /// Everything that is ours to stop on the main thread. Returns the new generation when the audio session must be handed back.
    private func tearDown() -> Int? {
        generation += 1
        starting?.cancel()
        starting = nil
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        if playingId != nil { playingId = nil }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        defer { holdsSession = false }
        return holdsSession ? generation : nil
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
