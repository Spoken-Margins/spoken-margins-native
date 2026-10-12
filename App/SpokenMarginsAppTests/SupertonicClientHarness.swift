import AVFoundation
import Foundation
import SessionKit
import SessionKitSupertonic
import XCTest
@testable import SpokenMarginsApp

/// Drives the Supertonic client across chunk boundaries the way a phone does, with the player's lifecycle
/// observers on (#353). Most client tests turn lifecycle off, so a chunk never ends through the path a
/// listener's phone takes, and the audit blockers on #301 and #346 lived exactly there.
///
/// - Each chunk is long, silent audio, so no player ends on its own during a test.
/// - A render can be held until the test releases it (`heldRenders`, counted in render order from 1).
/// - `finishPlayingChunk()` ends the playing chunk by posting the player item's own
///   `AVPlayerItemDidPlayToEndTime`, the notification the client observes on a real device.
///
/// A test reads like the listener's story:
///
///     let harness = try SupertonicClientHarness(heldRenders: [3])
///     try harness.start()
///     try harness.play(from: harness.chunkStarts[2] + 5)
///     await harness.finishPlayingChunk()
///     XCTAssertEqual(harness.playingChunkStart, harness.chunkStarts[3])
@MainActor
final class SupertonicClientHarness {
    nonisolated static let defaultText = (1...12)
        .map { "Sentence \($0) contains enough ordinary words to keep the narration moving through several chunks." }
        .joined(separator: " ")

    let client: SupertonicSpeechPlaybackClient
    let renderer: ScriptedSupertonicRenderer
    let targetId = "harness"
    let text: String
    /// Where each chunk starts, in spoken characters.
    let chunkStarts: [Int]
    private let players = HarnessPlayerLog()
    private let root: URL

    init(
        text: String = SupertonicClientHarness.defaultText,
        heldRenders: Set<Int> = [],
        chunkSeconds: Double = 30,
        stallRecoveryCooldown: Duration = .seconds(30)
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-harness-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let template = try Self.silentChunk(seconds: chunkSeconds, in: root)
        self.text = text
        chunkStarts = RenderedSpeechChunker.sourceSlices(from: SpeechTextNormalizer.normalize(text)).map(\.startOffset)
        renderer = ScriptedSupertonicRenderer(template: template, duration: chunkSeconds, heldRenders: heldRenders)
        let players = players
        client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { player, rate in
                players.started(player)
                player.volume = 0
                player.playImmediately(atRate: rate)
            },
            observesPlayerLifecycle: true,
            fallbackClient: RecordingFallbackAudioClient(),
            stallRecoveryCooldown: stallRecoveryCooldown
        )
    }

    /// Prepares the text and starts playing from the beginning, then waits until `renders` chunks have
    /// rendered (held ones don't count until released) and the first player has started.
    func start(waitingForRenders renders: Int = 2) async throws {
        _ = try client.prepareSpeechText(text)
        try client.play(targetId: targetId, from: 0)
        await waitForRenders(renders)
        _ = await waitForPlayerStarts(1)
    }

    func play(from offset: Int) throws { try client.play(targetId: targetId, from: offset) }

    /// How many players the client has started, one per chunk heard (or re-seated).
    var playerStarts: Int { players.count }

    /// The start of the chunk the client is playing, in spoken characters.
    var playingChunkStart: Int { client.debugActiveAudioState().startOffset }

    func releaseRender(_ index: Int) { renderer.release(index) }

    /// Waits until `count` renders have returned to the client.
    func waitForRenders(_ count: Int) async {
        for _ in 0..<250 where renderer.finishedCount < count { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Waits until `count` renders have started, held ones included.
    func waitForRenderStarts(_ count: Int) async {
        for _ in 0..<250 where renderer.startedCount < count { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Waits until the client has started `count` players in all; true when it has.
    func waitForPlayerStarts(_ count: Int) async -> Bool {
        for _ in 0..<150 where players.count < count { try? await Task.sleep(for: .milliseconds(20)) }
        return players.count >= count
    }

    /// Ends the playing chunk the way AVFoundation does on a phone: the newest player's item posts
    /// `AVPlayerItemDidPlayToEndTime`. The client's observer runs on the main queue, so the post is
    /// made off the main actor and this waits for it.
    func finishPlayingChunk() async {
        guard let item = players.newest?.currentItem else {
            XCTFail("no player is playing a chunk")
            return
        }
        let box = HarnessItemBox(item)
        await Task.detached {
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: box.item)
        }.value
    }

    func tearDown() {
        try? client.stop()
        renderer.releaseAll()
        try? FileManager.default.removeItem(at: root)
    }

    /// Silent 8 kHz mono audio: long enough that no chunk ends by itself, small on disk.
    private static func silentChunk(seconds: Double, in root: URL) throws -> URL {
        let url = root.appending(path: "chunk.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let frames = AVAudioFrameCount(8_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

/// Renders every chunk as a copy of one silent file. A held render (by render order, from 1) waits until
/// the test releases it; the rest return at once.
final class ScriptedSupertonicRenderer: SupertonicRendering, @unchecked Sendable {
    private let template: URL
    private let duration: TimeInterval
    private let lock = NSLock()
    private var held: Set<Int>
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var started = 0
    private var finished = 0

    init(template: URL, duration: TimeInterval, heldRenders: Set<Int>) {
        self.template = template
        self.duration = duration
        held = heldRenders
    }

    /// Renders started, held ones included.
    var startedCount: Int { lock.withLock { started } }
    /// Renders returned to the client.
    var finishedCount: Int { lock.withLock { finished } }

    func release(_ index: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            held.remove(index)
            return waiting.removeValue(forKey: index)
        }
        continuation?.resume()
    }

    func releaseAll() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            held.removeAll()
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        continuations.forEach { $0.resume() }
    }

    func render(
        text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult {
        let index = lock.withLock { () -> Int in started += 1; return started }
        if lock.withLock({ held.contains(index) }) {
            await withCheckedContinuation { continuation in
                let releasedAlready = lock.withLock { () -> Bool in
                    guard held.contains(index) else { return true }
                    waiting[index] = continuation
                    return false
                }
                if releasedAlready { continuation.resume() }
            }
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "scripted-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: template, to: url)
        lock.withLock { finished += 1 }
        return SupertonicNarrationResult(
            audioURL: url, duration: duration, sampleRate: 8_000, renderDuration: 0.01, sessionLoadCount: 1
        )
    }

    func discardGeneratedAudio(at url: URL) async { try? FileManager.default.removeItem(at: url) }
}

private final class HarnessPlayerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var players: [AVPlayer] = []
    var count: Int { lock.withLock { players.count } }
    var newest: AVPlayer? { lock.withLock { players.last } }
    func started(_ player: AVPlayer) { lock.withLock { players.append(player) } }
}

private struct HarnessItemBox: @unchecked Sendable {
    let item: AVPlayerItem
    init(_ item: AVPlayerItem) { self.item = item }
}
