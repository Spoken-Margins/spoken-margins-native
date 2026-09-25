import AVFoundation
import Foundation
import DesktopCore
import SessionKitSupertonic

struct DesktopRenderedAudio: Sendable {
    let url: URL
    let renderSeconds: TimeInterval
}

typealias DesktopRenderFunction = @Sendable (String) async throws -> DesktopRenderedAudio

/// Keeps generated audio and source-character offsets in one transport.
@MainActor
final class DesktopNeuralSpeech: NSObject, AVAudioPlayerDelegate {
    private var chunks: [DesktopSpeechChunk] = []
    private var player: AVAudioPlayer?
    private var playingChunk: DesktopSpeechChunk?
    private var playingURL: URL?
    private var nextIndex = 0
    private var renderTask: Task<DesktopRenderedAudio, Error>?
    private var prefetchedTask: Task<DesktopRenderedAudio, Error>?
    private var prefetchedIndex: Int?
    private var renderFunction: DesktopRenderFunction?
    private var generation = UUID()
    private var shouldPlay = false
    private var rate: Double = 1
    private var lastOffset = 0
    private(set) var isComplete = false
    private(set) var isWaiting = false
    private(set) var isTooSlow = false
    var onError: ((Error) -> Void)?

    var currentOffset: Int {
        guard let player, let chunk = playingChunk, player.duration > 0 else { return lastOffset }
        let ratio = max(0, min(1, player.currentTime / player.duration))
        return min(chunk.end, chunk.start + Int(Double(chunk.end - chunk.start) * ratio))
    }

    func play(text: String, from offset: Int, rate: Double, render: @escaping DesktopRenderFunction) {
        stop()
        renderFunction = render
        self.rate = rate
        shouldPlay = true
        lastOffset = max(0, min(offset, text.count))
        chunks = DesktopSpeechChunker.chunks(in: text, from: lastOffset)
        isComplete = chunks.isEmpty
        guard !chunks.isEmpty else { return }
        loadNext(using: render, token: generation)
    }

    func pause() {
        shouldPlay = false
        player?.pause()
        lastOffset = currentOffset
    }

    func resume(using render: @escaping DesktopRenderFunction) {
        shouldPlay = true
        renderFunction = render
        if let player {
            player.play()
        } else if renderTask == nil && nextIndex < chunks.count {
            loadNext(using: render, token: generation)
        }
    }

    func updateRate(_ value: Double) {
        rate = value
        player?.rate = Float(value)
    }

    func tick(using render: @escaping DesktopRenderFunction) {
        guard shouldPlay, let player, !player.isPlaying else { return }
        finishChunk(using: render)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map({ ObjectIdentifier($0) }) == playerID else { return }
            guard flag else {
                self.stop()
                self.onError?(DesktopNeuralFailure.invalidAudio)
                return
            }
            self.finishChunk(using: self.renderFunction)
        }
    }

    private func finishChunk(using render: DesktopRenderFunction?) {
        guard shouldPlay, let finishedPlayer = player else { return }
        if let chunk = playingChunk { lastOffset = chunk.end }
        finishedPlayer.delegate = nil
        self.player = nil
        playingChunk = nil
        if let url = playingURL { try? FileManager.default.removeItem(at: url) }
        playingURL = nil
        if nextIndex < chunks.count && renderTask == nil {
            guard let render else {
                shouldPlay = false
                onError?(DesktopNeuralFailure.invalidAudio)
                return
            }
            loadNext(using: render, token: generation)
        } else if nextIndex == chunks.count {
            isComplete = true
            shouldPlay = false
        }
    }

    func stop() {
        generation = UUID()
        shouldPlay = false
        renderTask?.cancel()
        prefetchedTask?.cancel()
        if let prefetchedTask {
            Task {
                if let result = try? await prefetchedTask.value {
                    try? FileManager.default.removeItem(at: result.url)
                }
            }
        }
        renderTask = nil
        prefetchedTask = nil
        prefetchedIndex = nil
        renderFunction = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        if let url = playingURL { try? FileManager.default.removeItem(at: url) }
        playingURL = nil
        playingChunk = nil
        chunks = []
        nextIndex = 0
        isComplete = false
        isWaiting = false
        isTooSlow = false
    }

    private func loadNext(using render: @escaping DesktopRenderFunction, token: UUID) {
        guard nextIndex < chunks.count else { return }
        let chunk = chunks[nextIndex]
        let index = nextIndex
        nextIndex += 1
        isWaiting = true
        let started = Date()
        let task: Task<DesktopRenderedAudio, Error>
        if prefetchedIndex == index, let prefetchedTask {
            task = prefetchedTask
            self.prefetchedTask = nil
            prefetchedIndex = nil
        } else {
            task = Task { try await render(chunk.text) }
        }
        renderTask = task
        Task { [weak self] in
            do {
                let result = try await task.value
                guard let self, self.generation == token else {
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }
                self.renderTask = nil
                self.isWaiting = false
                let player = try AVAudioPlayer(contentsOf: result.url)
                player.enableRate = true
                player.rate = Float(self.rate)
                player.delegate = self
                guard player.prepareToPlay() else { throw DesktopNeuralFailure.invalidAudio }
                self.player = player
                self.playingChunk = chunk
                self.playingURL = result.url
                self.lastOffset = chunk.start
                self.isTooSlow = result.renderSeconds > player.duration * 1.2 ||
                    Date().timeIntervalSince(started) > player.duration * 1.5
                if self.shouldPlay { player.play() }
                if self.nextIndex < self.chunks.count {
                    let next = self.chunks[self.nextIndex]
                    self.prefetchedIndex = self.nextIndex
                    self.prefetchedTask = Task { try await render(next.text) }
                }
            } catch {
                guard let self, self.generation == token else { return }
                self.renderTask = nil
                self.isWaiting = false
                self.shouldPlay = false
                self.onError?(error)
            }
        }
    }

}

enum DesktopNeuralFailure: LocalizedError {
    case invalidAudio
    var errorDescription: String? { "The voice generated audio that could not be played." }
}

@MainActor
final class DesktopSupertonicService {
    private let renderer: SupertonicNarrationRenderer?
    let setupError: String?

    init(directory: URL) {
        do {
            let assets = SupertonicAssetLocation(rootURL: Bundle.main.resourceURL!
                .appendingPathComponent("Supertonic", isDirectory: true))
            renderer = try SupertonicNarrationRenderer(
                assets: assets,
                outputDirectory: directory.appendingPathComponent("GeneratedSpeech", isDirectory: true))
            setupError = nil
        } catch {
            renderer = nil
            setupError = error.localizedDescription
        }
    }

    func renderFunction(voice: SupertonicVoiceID, language: String) -> DesktopRenderFunction? {
        guard let renderer, SupertonicNarrationRenderer.supportedLanguages.contains(language) else { return nil }
        return { text in
            let result = try await renderer.render(text: text, voice: voice, language: language)
            return DesktopRenderedAudio(url: result.audioURL, renderSeconds: result.renderDuration)
        }
    }
}
