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
/// - With `distinctTones`, each chunk is a tone of its own pitch instead, so a repeated or skipped chunk could be
///   told apart; a short `chunkSeconds` then lets the real queue play through several seams (#1762).
/// - A render can be held until the test releases it (`heldRenders`, counted in render order from 1).
/// - `finishPlayingChunk()` ends the playing chunk by posting the player item's own
///   `AVPlayerItemDidPlayToEndTime`, the notification the client observes on a real device.
/// - With `applicationIsActive` the client plays on a queue, and while the app is away the next chunk is queued
///   behind the playing one (#538). `finishPlayingChunkInTheQueue()` ends a chunk the way the system does then: the
///   queue moves on by itself, and the app hears about it afterwards.
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
    /// The iOS voice the client hands over to; records where it was asked to read from.
    let systemVoice = RecordingFallbackAudioClient()
    /// The reasons the client gave when it told the app the voice changed.
    let fallbackReasons = HarnessFallbackLog()
    /// The stall events the client logged, in order (`supertonic.stall`, `supertonic.stall_handover`, ...).
    let stallEvents = HarnessFallbackLog()
    /// One entry for each time the client asked the audio session to activate (#2101).
    let sessionActivations = HarnessFallbackLog()
    private let players = HarnessPlayerLog()
    private let root: URL

    init(
        text: String = SupertonicClientHarness.defaultText,
        heldRenders: Set<Int> = [],
        chunkSeconds: Double = 30,
        stallRecoveryCooldown: Duration = .seconds(30),
        standInRenders: Set<Int> = [],
        distinctTones: Bool = false,
        applicationIsActive: (@Sendable () -> Bool)? = nil,
        applicationIsInBackground: (@Sendable () -> Bool)? = nil,
        notificationCenter: NotificationCenter = .default,
        pressureRenderer: (any BundledVoiceRendering)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-harness-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let template = try Self.silentChunk(seconds: chunkSeconds, in: root)
        self.text = text
        chunkStarts = RenderedSpeechChunker.sourceSlices(from: SpeechTextNormalizer.normalize(text)).map(\.startOffset)
        renderer = ScriptedSupertonicRenderer(
            template: template, duration: chunkSeconds, heldRenders: heldRenders, standIns: standInRenders,
            distinctTones: distinctTones
        )
        let players = players
        let fallbackReasons = fallbackReasons
        let stallEvents = stallEvents
        let sessionActivations = sessionActivations
        client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionNotificationCenter: notificationCenter,
            audioSessionActivator: { sessionActivations.add("activate") },
            audioPlayerStarter: { player, rate in
                players.started(player)
                player.volume = 0
                player.playImmediately(atRate: rate)
            },
            observesPlayerLifecycle: true,
            pressureRenderer: pressureRenderer,
            fallbackClient: systemVoice,
            onFallback: { reason, _, _ in fallbackReasons.add(reason) },
            // The activation timing is a diagnostic, not a stall; a slow simulator must not add it to the lists tests compare.
            onStall: { kind, _ in if kind != "supertonic.session_activate" { stallEvents.add(kind) } },
            stallRecoveryCooldown: stallRecoveryCooldown,
            applicationIsActive: applicationIsActive,
            applicationIsInBackground: applicationIsInBackground
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

    /// Holds the next render the client starts, so a chunk the client renders again can't stand in for
    /// one it should already have.
    func holdNextRender() { renderer.hold(renderer.startedCount + 1) }

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

    /// The system turns down the newest player's start, as it did for a new player started with the app away
    /// (#1763): the player is at rate 0 and says why.
    func refuseTheNewestPlayersStart() {
        guard let player = players.newest else {
            XCTFail("no player has started")
            return
        }
        player.pause()
        NotificationCenter.default.post(
            name: AVPlayer.rateDidChangeNotification, object: player,
            userInfo: [AVPlayer.rateDidChangeReasonKey: AVPlayer.RateDidChangeReason.setRateFailed.rawValue]
        )
    }

    /// The newest player, when the client plays on a queue.
    var newestQueuePlayer: AVQueuePlayer? { players.newest as? AVQueuePlayer }

    /// How many items the newest player holds: the playing chunk, and the one queued behind it (#538).
    var itemsOnThePlayer: Int { (players.newest as? AVQueuePlayer)?.items().count ?? 0 }

    /// Waits until the chunk queued behind the playing one starts at `start` (nil: none is queued); true when it does.
    func waitForQueuedChunk(_ start: Int?) async -> Bool {
        for _ in 0..<150 where client.debugQueuedChunkStart != start { try? await Task.sleep(for: .milliseconds(20)) }
        return client.debugQueuedChunkStart == start
    }

    /// Waits until the client is playing the chunk that starts at `start`; true when it is.
    func waitForPlayingChunk(_ start: Int, seconds: Double = 3) async -> Bool {
        for _ in 0..<Int(seconds * 50) where playingChunkStart != start { try? await Task.sleep(for: .milliseconds(20)) }
        return playingChunkStart == start
    }

    /// The system moves a queue player on to its next item by itself, with the app suspended or not running any
    /// code. The app learns of it when it next runs (#538).
    func advanceTheQueueWithoutTellingTheApp() {
        guard let queue = players.newest as? AVQueuePlayer else {
            XCTFail("the client is not playing on a queue")
            return
        }
        queue.advanceToNextItem()
    }

    /// Ends the playing chunk as the system does for a chunk with another queued behind it: the queue moves on by
    /// itself, then the ended item posts its end notification.
    func finishPlayingChunkInTheQueue() async {
        guard let queue = players.newest as? AVQueuePlayer, let item = queue.currentItem else {
            XCTFail("the client is not playing a chunk on a queue")
            return
        }
        queue.advanceToNextItem()
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

final class HarnessFallbackLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String] = []
    var values: [String] { lock.withLock { reasons } }
    func add(_ reason: String) { lock.withLock { reasons.append(reason) } }
}

/// Renders every chunk as a copy of one silent file. A held render (by render order, from 1) waits until
/// the test releases it; the rest return at once.
final class ScriptedSupertonicRenderer: SupertonicRendering, @unchecked Sendable {
    private let template: URL
    private let duration: TimeInterval
    private let standIns: Set<Int>
    private let distinctTones: Bool
    private let lock = NSLock()
    private var held: Set<Int>
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var started = 0
    private var finished = 0

    init(
        template: URL, duration: TimeInterval, heldRenders: Set<Int>, standIns: Set<Int> = [], distinctTones: Bool = false
    ) {
        self.template = template
        self.duration = duration
        self.standIns = standIns
        self.distinctTones = distinctTones
        held = heldRenders
    }

    /// Renders started, held ones included.
    var startedCount: Int { lock.withLock { started } }
    /// Renders returned to the client.
    var finishedCount: Int { lock.withLock { finished } }

    func hold(_ index: Int) { lock.withLock { _ = held.insert(index) } }

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
        if distinctTones {
            try Self.writeTone(to: url, seconds: duration, frequency: 300 + 100 * Double(index))
        } else {
            try FileManager.default.copyItem(at: template, to: url)
        }
        lock.withLock { finished += 1 }
        return SupertonicNarrationResult(
            audioURL: url, duration: duration, sampleRate: 8_000, renderDuration: 0.01, sessionLoadCount: 1,
            engine: standIns.contains(index)
                ? SupertonicNarrationResult.systemVoiceEngine : SupertonicNarrationResult.supertonicEngine
        )
    }

    func discardGeneratedAudio(at url: URL) async { try? FileManager.default.removeItem(at: url) }

    /// 8 kHz mono sine tone: each render gets its own pitch, so a chunk played twice or out of order is audible
    /// in the player's output.
    private static func writeTone(to url: URL, seconds: Double, frequency: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let frames = AVAudioFrameCount(8_000 * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            samples[frame] = 0.5 * Float(sin(2 * Double.pi * frequency * Double(frame) / 8_000))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
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
