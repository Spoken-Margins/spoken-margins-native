import AVFoundation
import CryptoKit
import Foundation
import SessionKit
import SessionKitAudio
import SessionKitSupertonic
#if canImport(UIKit)
import UIKit
#endif

protocol SupertonicRendering: Sendable {
    func render(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult

    func discardGeneratedAudio(at url: URL) async
}

extension SupertonicNarrationRenderer: SupertonicRendering {}

/// The bundled voice that renders a chunk when Supertonic isn't allowed (#849). A seam so a test can hold one render
/// open while a play releases the voice; the app passes `KittenNarrationRenderer`.
protocol BundledVoiceRendering: Sendable {
    func render(text: String) async throws -> SupertonicNarrationResult
    func discardGeneratedAudio(at url: URL) async
}

extension KittenNarrationRenderer: BundledVoiceRendering {}

/// Background preparation's view of the shared renderer: every render is paced, whatever the
/// app's state, without touching the pacing the listener's live narration gets (#377).
struct BackgroundPreparationRenderer: SupertonicRendering {
    let base: SupertonicNarrationRenderer

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        try await base.render(text: text, voice: voice, language: language, speed: speed, synthesisSteps: synthesisSteps, pacing: .always)
    }

    func discardGeneratedAudio(at url: URL) async {
        await base.discardGeneratedAudio(at: url)
    }
}

struct PreparedChunkLookupResult: Sendable {
    var audioURL: URL
    var duration: TimeInterval
}

final class RenderedSpeechDiskCache: @unchecked Sendable {
    private let directory: URL
    private var limitBytes: Int
    private let fileManager: FileManager
    private let lock = NSLock()

    init(directory: URL, limitBytes: Int, fileManager: FileManager = .default) throws {
        self.directory = directory.standardizedFileURL
        self.limitBytes = max(1, limitBytes)
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(resourceValues)
        enforceLimit(protecting: nil)
    }

    func cachedAudio(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) -> SupertonicNarrationResult? {
        lock.withLock {
            let url = cacheURL(
                text: text,
                voice: voice,
                language: language,
                speed: speed,
                synthesisSteps: synthesisSteps
            )
            guard fileManager.fileExists(atPath: url.path),
                  let audio = try? AVAudioFile(forReading: url),
                  audio.processingFormat.sampleRate > 0,
                  audio.length > 0 else {
                try? fileManager.removeItem(at: url)
                return nil
            }
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return SupertonicNarrationResult(
                audioURL: url,
                duration: Double(audio.length) / audio.processingFormat.sampleRate,
                sampleRate: Int(audio.processingFormat.sampleRate.rounded()),
                renderDuration: 0,
                sessionLoadCount: 0
            )
        }
    }

    func store(
        _ result: SupertonicNarrationResult,
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) throws -> SupertonicNarrationResult {
        try lock.withLock {
            let destination = cacheURL(
                text: text,
                voice: voice,
                language: language,
                speed: speed,
                synthesisSteps: synthesisSteps
            )
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: result.audioURL, to: destination)
            }
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            enforceLimit(protecting: destination)
            return SupertonicNarrationResult(
                audioURL: destination,
                duration: result.duration,
                sampleRate: result.sampleRate,
                renderDuration: result.renderDuration,
                sessionLoadCount: result.sessionLoadCount,
                trimmedSilence: result.trimmedSilence
            )
        }
    }

    func owns(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == directory
    }

    func invalidate(_ url: URL) {
        guard owns(url) else { return }
        lock.withLock {
            try? fileManager.removeItem(at: url)
        }
    }

    func setLimitBytes(_ limitBytes: Int) {
        lock.withLock {
            self.limitBytes = max(1, limitBytes)
            enforceLimit(protecting: nil)
        }
    }

    var sizeBytes: Int {
        lock.withLock { cacheEntries().reduce(0) { $0 + $1.size } }
    }

    /// Deletes every cached file and returns the bytes freed.
    @discardableResult
    func removeAll() -> Int64 {
        lock.withLock { Self.removeAll(in: directory, fileManager: fileManager) }
    }

    /// The same, for a cache directory no instance has open.
    static func removeAll(in directory: URL, fileManager: FileManager = .default) -> Int64 {
        entries(in: directory, fileManager: fileManager).reduce(Int64(0)) { freed, entry in
            (try? fileManager.removeItem(at: entry.url)) == nil ? freed : freed + Int64(entry.size)
        }
    }

    private func cacheURL(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) -> URL {
        // v2: v1 entries can hold iOS-voice stand-ins cached as Supertonic before #311; they now
        // miss once and age out under the cache limit (#363 audit). v3: v2 entries still carry the
        // model's silence before and after the speech, so they miss once and render trimmed (#586).
        let payload = "supertonic-v3\u{1f}\(voice.rawValue)\u{1f}\(language)\u{1f}\(speed)\u{1f}\(synthesisSteps)\u{1f}\(text)"
        let digest = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: "\(digest).wav")
    }

    private func enforceLimit(protecting protectedURL: URL?) {
        var entries = cacheEntries().sorted { $0.modifiedAt < $1.modifiedAt }
        var total = entries.reduce(0) { $0 + $1.size }
        while total > limitBytes, let index = entries.firstIndex(where: { $0.url != protectedURL }) {
            let entry = entries.remove(at: index)
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func cacheEntries() -> [(url: URL, size: Int, modifiedAt: Date)] {
        Self.entries(in: directory, fileManager: fileManager)
    }

    private static func entries(in directory: URL, fileManager: FileManager) -> [(url: URL, size: Int, modifiedAt: Date)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "wav",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }
}

/// A warning backs off new inference across playback and Library workers.
/// Use monotonic time so clock changes cannot prematurely end the backoff.
final class SupertonicMemoryBackoff: @unchecked Sendable {
    private let lock = NSLock()
    private var blockedUntil: TimeInterval = 0

    func recordWarning(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock { blockedUntil = max(blockedUntil, now + 60) }
    }

    func isActive(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock { now < blockedUntil }
    }
}

/// Applies I14 (`SpeechEnginePolicy`) to the device: heat and memory pressure stop new
/// Supertonic inference; Low Power Mode and charging alone don't (#183).
enum SupertonicResourcePolicy {
    static let memoryBackoff = SupertonicMemoryBackoff()

    static func allowsRendering(processInfo: ProcessInfo = .processInfo) -> Bool {
        SpeechEnginePolicy.onDeviceRenderingBlock(currentConditions(processInfo: processInfo)) == nil
    }

    /// `isOnExternalPower` is for logging only; rendering never depends on it.
    static func currentConditions(
        processInfo: ProcessInfo = .processInfo,
        isOnExternalPower: Bool? = nil
    ) -> SpeechEngineConditions {
        SpeechEngineConditions(
            thermal: thermalLevel(processInfo.thermalState),
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            isOnExternalPower: isOnExternalPower,
            isRecoveringFromMemoryWarning: memoryBackoff.isActive()
        )
    }

    /// Whether the device is charging or full on power, for the fallback log. Nil off iOS.
    @MainActor
    static func isOnExternalPower() -> Bool? {
        #if canImport(UIKit) && os(iOS)
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        switch device.batteryState {
        case .charging, .full: return true
        case .unplugged: return false
        case .unknown: return nil
        @unknown default: return nil
        }
        #else
        return nil
        #endif
    }

    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> SpeechThermalLevel {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }
}

final class SupertonicSpeechPlaybackClient: NSObject, AudioPlaybackClient, @unchecked Sendable {
    typealias FallbackHandler = @Sendable (_ reason: String, _ charOffset: Int, _ targetId: String) -> Void
    typealias RestoreHandler = @Sendable (_ targetId: String) -> Void
    /// The bundled voice took a passage: `block` is the resource that refused Supertonic when Kitten took the
    /// generation (nil when it had cleared by then), not what the phone reports when the passage plays (#849 audit).
    typealias BundledVoiceHandler = @Sendable (_ block: SpeechFallbackReason?, _ charOffset: Int, _ targetId: String) -> Void
    /// A stall or its end, with the audio session's and player's state then (#288).
    typealias StallHandler = @Sendable (_ kind: String, _ fields: [String: String]) -> Void
    /// A pause, or a missing resume, the listener didn't ask for, with its cause (#538).
    typealias SystemPauseHandler = @Sendable (_ kind: String, _ fields: [String: String]) -> Void
    /// The article text a target speaks, without the engine's spoken preface ("Overview. …").
    typealias ArticleTextLookup = @Sendable (_ targetId: String) -> String?
    /// Which way a play request went, for diagnostics (#235).
    typealias ResumeDecisionHandler = @Sendable (_ fields: [String: String]) -> Void
    /// `stopReason` is set only with `.stopped`: the code that stopped generation (#314).
    typealias GenerationStateHandler = @Sendable (_ state: RenderedSpeechGenerationState, _ stopReason: String?) -> Void
    typealias GenerationProgressHandler = @Sendable (RenderedSpeechGenerationProgress) -> Void
    /// A new longest gap between one chunk ending and the next playing (#586).
    typealias ChunkHandOverGapHandler = @Sendable (ChunkHandOverGapRecorder.Gap) -> Void
    /// One line on how fast chunks render against how fast they play, after each chunk the phone renders (#540).
    typealias RenderPaceHandler = @Sendable (_ summary: String) -> Void
    /// The count of seams that came while the app was away, by how each went, after every one (#538).
    typealias BackgroundSeamHandler = @Sendable (_ summary: String) -> Void
    typealias PreparedAudioHandler = @Sendable (_ itemId: String, _ prepared: PreparedTextAudio) -> Void
    // Prepared audio is matched by the article plan's identity (NarrationChunkPlanner, #312), not by
    // comparing texts: plans are in the article's own coordinates, never the spoken preface's.
    typealias PreparationPlanHandler = @Sendable (_ itemId: String, _ articleIdentity: String, _ plan: [PreparedChunkPlan]) async -> Void
    typealias PreparedChunkHandler = @Sendable (_ itemId: String, _ articleIdentity: String, _ plan: PreparedChunkPlan, _ audioURL: URL, _ durationMs: Int, _ engine: String) async -> Void
    typealias PreparedChunkLookup = @Sendable (_ itemId: String, _ articleIdentity: String, _ plan: PreparedChunkPlan) async -> PreparedChunkLookupResult?
    typealias InterruptionHandler = @Sendable (AudioPlaybackInterruptionEvent) -> Void

    private struct RenderRequest: Sendable {
        var generation: UUID
        var targetId: String
        var startOffset: Int
        var sourceLength: Int
        var text: String
        var boundary: RenderedSpeechChunkBoundary
        /// Its index in the article plan; nil for a preface chunk or an article that isn't known.
        var articleIndex: Int? = nil
    }

    private struct CachedAudio {
        var url: URL
        var duration: TimeInterval
        var request: RenderRequest
    }

    /// The chunk after the playing one, already on the player's queue (#538). The cache keeps its audio until the
    /// player reaches it.
    private struct QueuedChunk {
        var cached: CachedAudio
        var item: AVPlayerItem
        var player: AVQueuePlayer
    }

    private final class RenderTaskControl: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var cancelled = false

        func install(_ task: Task<Void, Never>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                task.cancel()
            } else {
                self.task = task
                lock.unlock()
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    private enum TransportIntent: Equatable {
        case stopped
        case playing
        case paused
    }

    private enum ResumeAction {
        case none
        case resumePlayer(AVPlayer)
        case seekPlayer(AVPlayer, TimeInterval)
        case playCached(CachedAudio)
        case awaitPendingRender
        case renderPlanned(RenderRequest)
    }

    private let renderer: any SupertonicRendering
    private let voice: SupertonicVoiceID
    private let fallback: AudioPlaybackClient
    private let diskCache: RenderedSpeechDiskCache?
    private let onFallback: FallbackHandler?
    private let onGenerationStateChange: GenerationStateHandler?
    private let onGenerationProgress: GenerationProgressHandler?
    private let onChunkHandOverGap: ChunkHandOverGapHandler?
    private let onPreparedAudio: PreparedAudioHandler?
    private let preparedChunkLookup: PreparedChunkLookup?
    /// The bundled voice's saved stand-in for a chunk (#1680): played, not rendered again, while that voice holds
    /// narration, after a restart too. nil in tests that don't save audio.
    private let bundledVoiceChunkLookup: PreparedChunkLookup?
    private let onPreparationPlan: PreparationPlanHandler?
    private let onPreparedChunk: PreparedChunkHandler?
    private let interruptionHandler: InterruptionHandler?
    private let preparedAudioDirectory: URL?
    private let audioSessionNotificationCenter: NotificationCenter
    private let audioSessionActivator: (@Sendable () throws -> Void)?
    private let audioPlayerStarter: (@Sendable (AVPlayer, Float) -> Void)?
    private let observesPlayerLifecycle: Bool
    private let onDeviceRenderingAllowed: @Sendable () -> Bool
    /// The bundled Kitten voice (#849): renders a chunk when `onDeviceRenderingAllowed` refuses Supertonic, so a
    /// hot, low-power or memory-pressed phone keeps one steady voice instead of dropping to the iOS voice.
    /// nil in tests that exercise the iOS-voice fallback.
    private let pressureRenderer: (any BundledVoiceRendering)?
    /// Plays the cue that introduces the iOS voice when it takes over a passage (#934). nil in tests that don't listen.
    private let voiceChangeCue: (@Sendable () -> Void)?
    private let lock = NSLock()
    private let maxCharacters: Int
    private let startupBufferChunkCount: Int
    private let renderWaitLimit: Duration
    private var playbackRate: Float
    private var mixesWithOtherAudio = false
    private var lowersBackgroundAudio = false
    private var playbackVolume: Float = 1
    private var preparedSourceText = ""
    private var preparedSpeechProjection = NormalizedSpeechText(
        text: "",
        sourceOffsets: [],
        sourceLength: 0
    )
    private var activeSourceText = ""
    private var player: AVPlayer?
    /// The item the chunk bookkeeping below describes. With a queue the player may already have moved on to the
    /// next one, so the player's own current item is not the answer (#538).
    private var activeItem: AVPlayerItem?
    private var queuedChunk: QueuedChunk?
    private var queuedEndObserver: NSObjectProtocol?
    private var queuedStatusObservation: NSKeyValueObservation?
    private var backgroundSeams = BackgroundSeamLog()
    private var playbackEndObserver: NSObjectProtocol?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var activeAudioURL: URL?
    private var activeAudioDuration: TimeInterval = 0
    private var generation = UUID()
    /// Guarded by `lock`.
    private var handOverGaps = ChunkHandOverGapRecorder()
    private var currentTargetId: String?
    private var currentStartOffset = 0
    private var currentChunkLength = 0
    private var currentChunkBoundary = RenderedSpeechChunkBoundary.hard
    private var fallbackIsActive = false
    /// Counts plays of the iOS voice started outside the stall monitor: by the listener or by a
    /// hand-off from Supertonic. A stall sampled during an earlier one is stale (#432 audit).
    private var systemVoicePlayback = 0
    private var completedTargetId: String?
    private var playbackComplete = false
    private var pendingStartTargetId: String?
    private var startedTargetId: String?
    private var playbackFailure: String?
    private var renderedCache: [Int: CachedAudio] = [:]
    private var inFlightOffsets = Set<Int>()
    private var pendingAutoplayOffset: Int?
    private var transportIntent: TransportIntent = .stopped
    /// Items whose on-device generation is stopped, each with the reason it stopped (#314).
    private var generationDisabledReasons: [String: String] = [:]
    private var generationPlan: [RenderRequest] = []
    /// The article's own chunks as the plan saved for prepared audio has them, before the first chunk of a fallback
    /// play is split for a quick start. The same as `generationPlan` otherwise.
    private var preparationPlan: [RenderRequest] = []
    private var generationRenderOrder: [RenderRequest] = []
    private var generationResults: [Int: SupertonicPreparedChunk] = [:]
    /// Chunks the guard gave to the iOS voice. While any remain, the whole article isn't
    /// assembled into the item's audio, so the next play can try Supertonic again (#363 audit).
    private var standInOffsets: Set<Int> = []
    /// The stand-ins the bundled Kitten voice rendered (#849). They hold back an assembled file like any stand-in, but
    /// are not the iOS voice: no "iOS voice for this part" notice, no voice-change chime.
    private var bundledVoiceOffsets: Set<Int> = []
    /// The generation the bundled Kitten voice holds (#849 audit, I14): once Kitten renders a chunk, it renders the
    /// rest of that generation too, so Supertonic comes back only at a play, never mid-sentence.
    private var bundledVoiceGeneration: UUID?
    /// The generation whose listener was told the bundled voice took over (#849 audit, I14: a visible, logged reason).
    private var bundledVoiceNoticeGeneration: UUID?
    /// What refused Supertonic when the bundled voice took `bundledVoiceGeneration`, for the notice (#849 audit).
    private var bundledVoiceBlock: SpeechFallbackReason?
    /// The generation playing a run of saved Supertonic audio in place of the bundled voice (#1680). Set at a seam
    /// for a long enough run; the run ends at its first chunk without saved audio, where the bundled voice takes the
    /// generation back.
    private var savedRunGeneration: UUID?
    /// The playhead chunk as the article plan has it, keyed by its start, when a fallback play split it for a quick
    /// start (#849 audit): saved Supertonic audio for the whole chunk still plays when there is some.
    private var fastStartOriginals: [Int: RenderRequest] = [:]
    /// Decides which passage gets the voice-change cue, per generation (#934).
    private var voiceChangeCueDecider = NarrationVoiceChangeCue()
    private var voiceChangeCueGeneration: UUID?
    private var initialPlaybackOffset: Int?
    private var initialRequestedSpokenOffset: Int?
    private var failedRenderReasons: [Int: String] = [:]
    /// Targets in the system voice because of heat or memory pressure (I14: these come back
    /// to Supertonic at the next play once the condition clears).
    private var resourceFallbackTargetIds: Set<String> = []
    /// The generation whose render queue behind a kept chunk was held back when a hand-over ended, by a stop or
    /// because the chosen voice could not render then. A memory warning's stop lifts by itself at a later play,
    /// which starts that queue then (#540 audit).
    private var heldRenderQueueGeneration: UUID?
    private let onRestore: RestoreHandler?
    /// Told when the bundled Kitten voice starts playing in place of Supertonic (#849 audit, I14), with the resource
    /// that refused Supertonic when Kitten took over, so the listener sees why and diagnostics log it. Never after a
    /// play released the voice. `onRestore` clears it.
    private let onBundledVoice: BundledVoiceHandler?
    private let onStall: StallHandler?
    private let onSystemPause: SystemPauseHandler?
    private let onRenderPace: RenderPaceHandler?
    /// Whether the app is in front. With it the player is a queue, and while the app is away the next rendered
    /// chunk goes onto it before the playing one ends, so the seam needs no app code (#538). nil leaves every seam as
    /// it was: one player per chunk. Read on the main thread; anywhere else the app counts as in front.
    private let applicationIsActive: (@Sendable () -> Bool)?
    private let onBackgroundSeams: BackgroundSeamHandler?
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Background time over the moment between one chunk ending and the next playing (#540).
    private let handOverHold: HandOverBackgroundHold?
    /// Background time while an interruption waits to end, so a backgrounded app isn't suspended before iOS
    /// says it is over (#1434).
    private let interruptionHold: InterruptionBackgroundHold?
    /// Guarded by `lock`.
    private var renderPace = RenderPaceLog()
    private var handOverHoldRequested = false
    /// A hand-over to the iOS voice that has queued its speech but not yet begun (#540). The stalled chunk
    /// and the notice to the app wait for the voice to speak; if it never does, the stall pauses for a tap.
    private struct HandOverAwaitingStart {
        var targetId: String
        var sourceOffset: Int
        var reason: String
        var stopReason: String
        var kept: URL?
        var playback: Int
        var chunkStart: Int
        var chunkLength: Int
        var stallFields: [String: String] = [:]
    }
    private var handOverAwaitingStart: HandOverAwaitingStart?
    /// When the current player was made, and when its start was asked for. A player with no start was
    /// never started: the delay before it didn't run, or the start was refused before it got there (#540).
    private var playerCreatedAt: ContinuousClock.Instant?
    private var playerStartedAt: ContinuousClock.Instant?
    /// The player's own last change of rate and the system's reason for it (#540). It has its own lock: the
    /// system may post the change on the thread that set the rate, which can be inside `lock` (a pause while
    /// re-seating), and the observer taking `lock` there would wait on itself.
    private let rateChangeLock = NSLock()
    private var lastRateChange: (reason: String, rate: Float, at: ContinuousClock.Instant)?
    private var rateChangeObserver: NSObjectProtocol?
    private let stallThreshold: Duration
    private let stallSampleInterval: Duration
    private let stallRecoveryCooldown: Duration
    /// The chunk the player is playing, so a stalled player can be re-seated at the same point.
    private var activeRequest: RenderRequest?
    private var stallMonitor: Task<Void, Never>?
    private var lastStallRecovery: ContinuousClock.Instant?
    #if DEBUG
    /// Runs as the stall monitor is about to stop, so a test can resume playback exactly then.
    var debugStallMonitorWillExit: (@Sendable () -> Void)?
    /// Runs between a stall sample and its handling, so a test can switch items exactly then.
    var debugStallWillBeHandled: (@Sendable () -> Void)?
    /// How often the client asked to stop lowering other apps' audio.
    private(set) var debugBackgroundAudioReleaseCount = 0
    var debugHasStallMonitor: Bool { lock.withLock { stallMonitor != nil } }
    /// Where the chunk queued behind the playing one starts, nil when none is queued (#538).
    var debugQueuedChunkStart: Int? { lock.withLock { queuedChunk?.cached.request.startOffset } }
    /// The count of seams that came with the app away, as the export shows it (#538).
    var debugBackgroundSeamSummary: String? { lock.withLock { backgroundSeams.summary } }
    #endif
    private let articleText: ArticleTextLookup?
    /// Where the article starts after a spoken preface, in spoken and source characters. Prepared
    /// audio covers the article alone, so the article is planned as its own section (#258).
    private var articleSpokenStart = 0
    private var articleSourceStart = 0
    /// The article plan's identity for this generation; nil when no chunk can match prepared audio.
    private var articleIdentity: String?
    private let onResumeDecision: ResumeDecisionHandler?
    private var preparedAudioAssemblyStarted = false
    private var generationState = RenderedSpeechGenerationState.inactive
    private var generationStopReason: String?
    private var shouldResumeAfterInterruption = false
    private var activeRenderControl: RenderTaskControl?

    /// Speculative Library work can share the serial renderer only while the
    /// listener has two contiguous committed chunks beyond the audible chunk.
    var canYieldRendererToLibrary: Bool {
        lock.withLock {
            guard transportIntent == .playing else { return true }
            guard !fallbackIsActive, pendingAutoplayOffset == nil, startedTargetId != nil else { return false }
            if generationState == .ready { return true }
            var offset = currentStartOffset + currentChunkLength
            for _ in 0..<2 {
                if offset >= preparedSpeechProjection.text.count { return true }
                guard let chunk = renderedCache[offset] else { return false }
                offset += chunk.request.sourceLength
            }
            return true
        }
    }

    init(
        renderer: any SupertonicRendering,
        voice: SupertonicVoiceID,
        speed: Float,
        fallbackVoiceIdentifier: String?,
        fallbackRate: Float,
        maxCharacters: Int = RenderedSpeechChunker.spokenCostBudget,
        startupBufferChunkCount: Int = 1,
        diskCache: RenderedSpeechDiskCache? = nil,
        preparedAudioDirectory: URL? = nil,
        audioSessionNotificationCenter: NotificationCenter = .default,
        audioSessionActivator: (@Sendable () throws -> Void)? = nil,
        audioPlayerStarter: (@Sendable (AVPlayer, Float) -> Void)? = nil,
        observesPlayerLifecycle: Bool = true,
        voiceChangeCue: (@Sendable () -> Void)? = nil,
        onDeviceRenderingAllowed: @escaping @Sendable () -> Bool = { SupertonicResourcePolicy.allowsRendering() },
        pressureRenderer: (any BundledVoiceRendering)? = nil,
        fallbackClient: AudioPlaybackClient? = nil,
        interruptionHandler: InterruptionHandler? = nil,
        onGenerationStateChange: GenerationStateHandler? = nil,
        onGenerationProgress: GenerationProgressHandler? = nil,
        onChunkHandOverGap: ChunkHandOverGapHandler? = nil,
        onPreparationPlan: PreparationPlanHandler? = nil,
        onPreparedChunk: PreparedChunkHandler? = nil,
        articleText: ArticleTextLookup? = nil,
        preparedChunkLookup: PreparedChunkLookup? = nil,
        bundledVoiceChunkLookup: PreparedChunkLookup? = nil,
        onPreparedAudio: PreparedAudioHandler? = nil,
        onFallback: FallbackHandler? = nil,
        onRestore: RestoreHandler? = nil,
        onBundledVoice: BundledVoiceHandler? = nil,
        onStall: StallHandler? = nil,
        onSystemPause: SystemPauseHandler? = nil,
        stallThreshold: Duration = .seconds(5),
        stallSampleInterval: Duration = .seconds(1),
        stallRecoveryCooldown: Duration = .seconds(30),
        onResumeDecision: ResumeDecisionHandler? = nil,
        renderWaitLimit: Duration = .seconds(15),
        onRenderPace: RenderPaceHandler? = nil,
        handOverHold: HandOverBackgroundHold? = nil,
        interruptionHold: InterruptionBackgroundHold? = nil,
        applicationIsActive: (@Sendable () -> Bool)? = nil,
        onBackgroundSeams: BackgroundSeamHandler? = nil
    ) {
        self.renderer = renderer
        self.voice = voice
        self.playbackRate = max(0.25, min(2.0, speed))
        if let fallbackClient {
            self.fallback = fallbackClient
        } else if let identifier = fallbackVoiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !identifier.isEmpty {
            self.fallback = SystemSpeechPlaybackClient(
                voiceIdentifier: identifier,
                speechRate: fallbackRate
            )
        } else {
            // The default client follows the user's Spoken Content setting.
            // Constructing the explicit initializer with a nil identifier
            // instead selects Apple's generic app voice.
            self.fallback = SystemSpeechPlaybackClient()
        }
        self.diskCache = diskCache
        self.audioSessionNotificationCenter = audioSessionNotificationCenter
        self.audioSessionActivator = audioSessionActivator
        self.audioPlayerStarter = audioPlayerStarter
        self.observesPlayerLifecycle = observesPlayerLifecycle
        self.voiceChangeCue = voiceChangeCue
        self.onDeviceRenderingAllowed = onDeviceRenderingAllowed
        self.pressureRenderer = pressureRenderer
        self.interruptionHandler = interruptionHandler
        self.maxCharacters = maxCharacters
        self.startupBufferChunkCount = max(1, startupBufferChunkCount)
        self.preparedAudioDirectory = preparedAudioDirectory
        self.onGenerationStateChange = onGenerationStateChange
        self.onGenerationProgress = onGenerationProgress
        self.onChunkHandOverGap = onChunkHandOverGap
        self.onPreparationPlan = onPreparationPlan
        self.onPreparedChunk = onPreparedChunk
        self.preparedChunkLookup = preparedChunkLookup
        self.bundledVoiceChunkLookup = bundledVoiceChunkLookup
        self.onPreparedAudio = onPreparedAudio
        self.onFallback = onFallback
        self.onRestore = onRestore
        self.onBundledVoice = onBundledVoice
        self.onStall = onStall
        self.onSystemPause = onSystemPause
        self.stallThreshold = stallThreshold
        self.stallSampleInterval = stallSampleInterval
        self.stallRecoveryCooldown = stallRecoveryCooldown
        self.articleText = articleText
        self.onResumeDecision = onResumeDecision
        self.renderWaitLimit = renderWaitLimit
        self.onRenderPace = onRenderPace
        self.handOverHold = handOverHold
        self.interruptionHold = interruptionHold
        self.applicationIsActive = applicationIsActive
        self.onBackgroundSeams = onBackgroundSeams
        super.init()
        installAudioSessionObservers()
        installLifecycleObservers()
    }

    deinit {
        playerItemStatusObservation?.invalidate()
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        if let rateChangeObserver {
            NotificationCenter.default.removeObserver(rateChangeObserver)
        }
        if handOverHoldRequested, let hold = handOverHold {
            Task { @MainActor in hold.nextChunkMoving() }
        }
        if let hold = interruptionHold {
            Task { @MainActor in hold.listenerActed() }
        }
        for observer in audioSessionObservers {
            audioSessionNotificationCenter.removeObserver(observer)
        }
        for observer in lifecycleObservers {
            audioSessionNotificationCenter.removeObserver(observer)
        }
        if let queuedEndObserver {
            NotificationCenter.default.removeObserver(queuedEndObserver)
        }
        queuedStatusObservation?.invalidate()
    }

    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {
        try setPlaybackRate(Double(rate / 0.5))
        try fallback.configureSpeechSettings(voiceIdentifier: voiceIdentifier, rate: rate)
    }

    func prepareSpeechText(_ text: String) throws -> String {
        let projection = SpeechTextNormalizer.normalizeWithSourceOffsets(text)
        lock.withLock {
            preparedSourceText = text
            preparedSpeechProjection = projection
        }
        return projection.text
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        try play(targetId: targetId, from: charOffset, isSeek: false)
    }

    /// A listener's explicit move: it moves even within `livePositionTolerance` of the live
    /// position, which only absorbs how far a repeated play or restart trails it (#346 audit).
    func play(targetId: String, seekingTo charOffset: Int) throws {
        try play(targetId: targetId, from: charOffset, isSeek: true)
    }

    private func play(targetId: String, from charOffset: Int, isSeek: Bool) throws {
        applyQueuedAdvance(finished: nil)
        settleHandOverBeforePlay()
        interruptionWaitEnded(.listenerActed)
        try activateAudioSession(forPlayback: false)
        restoreOnDeviceRenderingIfConditionCleared(targetId: targetId)
        let usesStoppedGeneration = lock.withLock {
            shouldResumeAfterInterruption = false
            return generationDisabledReasons[targetId] != nil
                || (fallbackIsActive && currentTargetId == targetId)
        }
        if usesStoppedGeneration {
            try fallback.play(targetId: targetId, from: charOffset)
            let spokenOffset = spokenOffset(forSourceOffset: charOffset)
            lock.withLock {
                fallbackIsActive = true
                systemVoicePlayback += 1
                currentTargetId = targetId
                currentStartOffset = spokenOffset
                transportIntent = .playing
            }
            reportGenerationState(
                .stopped,
                stopReason: lock.withLock { generationDisabledReasons[targetId] } ?? SpeechGenerationStopReason.generationDisabledCode
            )
            startStallMonitorIfNeeded()
            return
        }
        let spokenOffset = resumeSpokenOffset(targetId: targetId, sourceOffset: charOffset)
        replaceBundledVoiceChunks(after: spokenOffset, targetId: targetId)
        let before = resumeDiagnostics(targetId: targetId, spokenOffset: spokenOffset)
        let action = resumeAction(targetId: targetId, fromSpokenOffset: spokenOffset, isSeek: isSeek)
        reportResumeDecision(action, before: before)
        switch action {
        case .resumePlayer(let player):
            try activateAudioSession()
            player.playImmediately(atRate: lock.withLock { playbackRate })
            startStallMonitorIfNeeded()
            return
        case .seekPlayer(let player, let time):
            try activateAudioSession()
            player.pause()
            player.seek(
                to: CMTime(seconds: time, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            player.playImmediately(atRate: lock.withLock { playbackRate })
            startStallMonitorIfNeeded()
            return
        case .playCached(let cached):
            playRenderedAudio(cached.url, duration: cached.duration, request: cached.request)
            return
        case .awaitPendingRender:
            return
        case .renderPlanned(let request):
            enqueueRender(request, shouldPlayWhenReady: false)
            return
        case .none:
            break
        }
        guard let request = nextRequest(targetId: targetId, fromSpokenOffset: spokenOffset) else {
            throw SessionKitError.invalidCommandForState("supertonic_playback_text_empty")
        }
        enqueueRender(request, shouldPlayWhenReady: false)
    }

    /// I14 for the bundled voice: once Supertonic is allowed again, a play (resume, seek, next item) releases the
    /// generation from Kitten and lets go of the chunks after the one holding the playhead that are rendered and
    /// waiting, from the first Kitten one on, so they render again with Supertonic. The whole waiting run goes, not
    /// only its Kitten chunks: the render chain stops at the first chunk still waiting, so a Kitten chunk past it
    /// would never be rendered again (#849 audit). The chunk holding the playhead is finished first, so the voice
    /// never changes mid-sentence (#849).
    private func replaceBundledVoiceChunks(after spokenOffset: Int, targetId: String) {
        guard pressureRenderer != nil, onDeviceRenderingAllowed() else { return }
        let work = lock.withLock { () -> (urls: [URL], restart: RenderRequest?, told: Bool) in
            let told = bundledVoiceNoticeGeneration != nil
            bundledVoiceGeneration = nil
            bundledVoiceNoticeGeneration = nil
            bundledVoiceBlock = nil
            let order = generationRenderOrder
            guard let first = order.firstIndex(where: {
                $0.startOffset > spokenOffset && bundledVoiceOffsets.contains($0.startOffset)
                    && renderedCache[$0.startOffset] != nil && !inFlightOffsets.contains($0.startOffset)
            }) else { return ([], nil, told) }
            var stale: [RenderRequest] = []
            for planned in order[first...] {
                guard renderedCache[planned.startOffset] != nil, !inFlightOffsets.contains(planned.startOffset) else { break }
                stale.append(planned)
            }
            var urls: Set<URL> = []
            for planned in stale {
                let offset = planned.startOffset
                if let cached = renderedCache.removeValue(forKey: offset) { urls.insert(cached.url) }
                if let result = generationResults.removeValue(forKey: offset) { urls.insert(result.audioURL) }
                standInOffsets.remove(offset)
                bundledVoiceOffsets.remove(offset)
            }
            if let active = activeAudioURL { urls.remove(active) }
            return (Array(urls), stale.first, told)
        }
        if work.told { onRestore?(targetId) }
        for url in work.urls { discardAudio(url) }
        if let restart = work.restart { enqueueRender(restart, shouldPlayWhenReady: false) }
    }

    /// Whether the bundled voice holds `generation` (#849 audit).
    private func holdsBundledVoice(for generation: UUID) -> Bool {
        lock.withLock { bundledVoiceGeneration == generation }
    }

    /// Kitten renders the rest of `generation` from here on, until a play releases it (#849 audit).
    private func holdBundledVoice(for generation: UUID) {
        let block = SpeechEnginePolicy.onDeviceRenderingBlock(SupertonicResourcePolicy.currentConditions())
        lock.withLock {
            guard self.generation == generation else { return }
            if bundledVoiceGeneration != generation { bundledVoiceBlock = block }
            bundledVoiceGeneration = generation
            savedRunGeneration = nil
        }
    }

    /// #1680: while the bundled voice holds narration, or Supertonic may not render now, whether `request` plays saved
    /// Supertonic audio. Inside a saved run, any chunk with saved audio does. Otherwise only a chunk at a seam (a
    /// paragraph's first chunk boundary, or where the play starts) does, and only when the saved run from it is long
    /// enough (`SavedVoiceRunRule`); the run then starts and the bundled voice lets go of the generation. So the
    /// voice changes at most once each way per run.
    private func choosesSavedSupertonicRun(for request: RenderRequest) async -> Bool {
        let state = lock.withLock { () -> (inRun: Bool, playStart: Bool, rate: Double, plan: [RenderRequest], index: Int,
                                           source: String, projection: NormalizedSpeechText)? in
            guard generation == request.generation else { return nil }
            let canonical = preparationPlan.contains { $0.startOffset == request.startOffset }
            let plan = canonical ? preparationPlan : generationPlan
            guard let index = plan.firstIndex(where: { $0.startOffset == request.startOffset }) else { return nil }
            return (savedRunGeneration == request.generation,
                    request.startOffset == generationRenderOrder.first?.startOffset,
                    Double(playbackRate), plan, index, preparedSourceText, preparedSpeechProjection)
        }
        guard let state else { return false }
        let plan = state.plan
        let atSeam = state.playStart || SavedVoiceRunRule.isParagraphSeam(
            in: state.source, at: state.index,
            sourceStart: { state.projection.sourceOffset(atSpokenCharacterOffset: plan[$0].startOffset) },
            endsSentence: { plan[$0].boundary == .sentence || plan[$0].boundary == .hard })
        // Away from a seam, outside a run, nothing can change: no lookups on the hot path.
        guard state.inRun || atSeam else { return false }
        let ahead = plan[state.index...]
        guard let first = ahead.first, let firstDuration = await savedSupertonicAudio(for: first)?.duration else {
            // The run ends at its first chunk without saved audio.
            if state.inRun { lock.withLock { if savedRunGeneration == request.generation { savedRunGeneration = nil } } }
            return false
        }
        if state.inRun { return true }
        var run = [firstDuration]
        var reachesEnd = ahead.count == 1
        for planned in ahead.dropFirst() {
            if SavedVoiceRunRule.isLongEnough(run, reachesEnd: false, playbackRate: state.rate) { break }
            guard let duration = await savedSupertonicAudio(for: planned)?.duration else { break }
            run.append(duration)
            if planned.startOffset == ahead.last?.startOffset { reachesEnd = true }
        }
        let choice = SavedVoiceRunRule.choice(inSavedRun: false, atSeam: true, savedRun: run, reachesEnd: reachesEnd,
                                              playbackRate: state.rate)
        guard choice == .savedSupertonic else { return false }
        return lock.withLock {
            guard generation == request.generation else { return false }
            savedRunGeneration = request.generation
            if bundledVoiceGeneration == request.generation { bundledVoiceGeneration = nil }
            return true
        }
    }

    /// A play's first chunk came from the bundled voice's saved audio, not a render: the export says so, since the
    /// resume decision before it can only say `restart_rendering` after a cold launch (#1680).
    private func reportSavedBundledVoiceStart(request: RenderRequest) {
        guard let onResumeDecision,
              lock.withLock({ generation == request.generation && startedTargetId == nil
                  && request.startOffset == generationRenderOrder.first?.startOffset }) else { return }
        onResumeDecision(["path": "play_saved", "engine": KittenNarrationRenderer.engine,
                          "chunkStart": String(request.startOffset)])
    }

    /// The bundled voice's saved audio for `request` (#1680): the whole chunk's when `request` is a split head, else
    /// the chunk's own.
    private func savedBundledVoiceAudio(
        for request: RenderRequest, articleChunk: (identity: String, plan: PreparedChunkPlan)?
    ) async -> (request: RenderRequest, result: SupertonicNarrationResult)? {
        if let unsplit = await savedAudioForUnsplitChunk(request, bundledVoice: true) { return unsplit }
        guard let articleChunk,
              let saved = await bundledVoiceChunkLookup?(request.targetId, articleChunk.identity, articleChunk.plan) else {
            return nil
        }
        return (request, SupertonicNarrationResult(
            audioURL: saved.audioURL, duration: saved.duration, sampleRate: 0, renderDuration: 0,
            sessionLoadCount: 0, engine: KittenNarrationRenderer.engine
        ))
    }

    /// The saved Supertonic audio for `planned`, from prepared audio or the disk cache; nil when there is none.
    private func savedSupertonicAudio(for planned: RenderRequest) async -> SupertonicNarrationResult? {
        let article = lock.withLock { (identity: articleIdentity, start: articleSpokenStart) }
        if let identity = article.identity, let index = planned.articleIndex,
           let recovered = await preparedChunkLookup?(planned.targetId, identity, PreparedChunkPlan(
               index: index, startOffset: planned.startOffset - article.start,
               sourceLength: planned.sourceLength, text: planned.text)) {
            return SupertonicNarrationResult(audioURL: recovered.audioURL, duration: recovered.duration, sampleRate: 0,
                                             renderDuration: 0, sessionLoadCount: 0)
        }
        return diskCache?.cachedAudio(text: planned.text, voice: voice, language: "en", speed: 1.0, synthesisSteps: 8)
    }

    /// I14: the chosen voice comes back once the condition that forced the fallback clears.
    /// It switches at a play (resume, seek, next item), never mid-sentence.
    private func restoreOnDeviceRenderingIfConditionCleared(targetId: String) {
        let restoresVoice = onDeviceRenderingAllowed() && lock.withLock { resourceFallbackTargetIds.contains(targetId) }
        if restoresVoice { try? fallback.pause() }
        let restartsHeldQueue = lock.withLock { () -> Bool in
            if restoresVoice {
                resourceFallbackTargetIds.remove(targetId)
                generationDisabledReasons.removeValue(forKey: targetId)
                fallbackIsActive = false
            }
            defer { if restoresVoice { heldRenderQueueGeneration = nil } }
            return heldRenderQueueGeneration == generation
        }
        if restoresVoice { onRestore?(targetId) }
        // A hand-over that ended while a memory warning or heat held back the queue behind the kept chunk leaves it
        // held; the kept chunk plays from the cache now, so the chunk after it must start rendering with it, not
        // after it. Heat clears without a fallback marker, so this runs whether or not the voice was restored; the
        // restart itself checks that rendering is allowed and that nothing stopped generation (#540 audit).
        if restartsHeldQueue { restartRenderQueueBehindKeptChunk() }
    }

    func currentCharOffset() -> Int? {
        applyQueuedAdvance(finished: nil)
        let snapshot = lock.withLock {
            (
                fallbackIsActive,
                currentStartOffset,
                currentChunkLength,
                player,
                activeAudioDuration,
                preparedSpeechProjection,
                initialRequestedSpokenOffset
            )
        }
        if snapshot.0 { return fallback.currentCharOffset() }
        let currentTime = playerTime(snapshot.3)
        guard snapshot.4 > 0, snapshot.2 > 0, currentTime.isFinite else {
            return snapshot.5.sourceOffset(
                atSpokenCharacterOffset: max(snapshot.1, snapshot.6 ?? snapshot.1)
            )
        }
        let fraction = max(0, min(1, currentTime / snapshot.4))
        let spokenOffset = max(
            snapshot.1 + Int((Double(snapshot.2) * fraction).rounded(.down)),
            snapshot.6 ?? snapshot.1
        )
        return snapshot.5.sourceOffset(atSpokenCharacterOffset: spokenOffset)
    }

    func currentRecoveryCharOffset() -> Int? {
        applyQueuedAdvance(finished: nil)
        let snapshot = lock.withLock {
            (fallbackIsActive, currentStartOffset, preparedSpeechProjection, initialRequestedSpokenOffset)
        }
        return snapshot.0
            ? fallback.currentRecoveryCharOffset()
            : snapshot.2.sourceOffset(atSpokenCharacterOffset: max(snapshot.1, snapshot.3 ?? snapshot.1))
    }

    #if DEBUG
    func debugRenderedCacheOffsets() -> [Int] {
        lock.withLock { renderedCache.keys.sorted() }
    }

    func debugActiveAudioState() -> (hasURL: Bool, duration: TimeInterval, targetId: String?, startOffset: Int) {
        lock.withLock { (activeAudioURL != nil, activeAudioDuration, currentTargetId, currentStartOffset) }
    }

    func debugFinishActiveChunk() {
        guard let item = lock.withLock({ player?.currentItem }) else { return }
        playbackItemFinished(item)
    }
    #endif

    func currentPlaybackPosition() -> PlaybackPosition? {
        applyQueuedAdvance(finished: nil)
        let snapshot = lock.withLock {
            (
                currentTargetId,
                currentStartOffset,
                currentChunkLength,
                playbackRate,
                preparedSourceText.count,
                preparedSpeechProjection
            )
        }
        guard let targetId = snapshot.0 else { return nil }
        let sourceChunkStart = snapshot.5.sourceOffset(atSpokenCharacterOffset: snapshot.1)
        let start = max(0, min(currentCharOffset() ?? sourceChunkStart, snapshot.4))
        let sourceChunkEnd = snapshot.5.sourceOffset(
            atSpokenCharacterOffset: snapshot.1 + snapshot.2
        )
        return PlaybackPosition(
            targetType: .itemTextTTS,
            targetId: targetId,
            textStart: start,
            textEnd: min(snapshot.4, max(start + 1, sourceChunkEnd)),
            playbackRate: Double(snapshot.3),
            anchorConfidence: .textRange
        )
    }

    func setPlaybackRate(_ rate: Double) throws {
        let clamped = Float(max(0.25, min(2.0, rate)))
        let state = lock.withLock { () -> (usesFallback: Bool, activePlayer: AVPlayer?) in
            playbackRate = clamped
            return (fallbackIsActive, transportIntent == .playing ? player : nil)
        }
        if state.usesFallback {
            try fallback.setPlaybackRate(Double(clamped))
        } else if state.activePlayer?.timeControlStatus == .playing {
            state.activePlayer?.rate = clamped
        }
    }

    func setMixesWithOtherAudio(_ enabled: Bool) throws {
        let state = lock.withLock { () -> (usesFallback: Bool, hasActivePlayer: Bool) in
            mixesWithOtherAudio = enabled
            return (fallbackIsActive, player != nil && transportIntent == .playing && !playbackComplete)
        }
        try fallback.setMixesWithOtherAudio(enabled)
        if state.hasActivePlayer, !state.usesFallback {
            try activateAudioSession()
        }
    }

    func setLowersBackgroundAudio(_ enabled: Bool) throws {
        let state = lock.withLock { () -> (usesFallback: Bool, isPlaying: Bool) in
            lowersBackgroundAudio = enabled
            return (fallbackIsActive, player != nil && transportIntent == .playing && !playbackComplete)
        }
        try fallback.setLowersBackgroundAudio(enabled)
        if state.isPlaying, !state.usesFallback {
            try activateAudioSession()
        }
    }

    func setPlaybackVolume(_ volume: Float) throws {
        let clamped = max(0, min(1, volume))
        let state = lock.withLock { () -> (usesFallback: Bool, activePlayer: AVPlayer?) in
            playbackVolume = clamped
            return (fallbackIsActive, player)
        }
        try fallback.setPlaybackVolume(min(1, clamped))
        if !state.usesFallback {
            state.activePlayer?.volume = min(1, clamped)
        }
    }

    func isPlaybackComplete(targetId: String) -> Bool {
        let snapshot = lock.withLock {
            (fallbackIsActive, playbackComplete && completedTargetId == targetId)
        }
        return snapshot.0 ? fallback.isPlaybackComplete(targetId: targetId) : snapshot.1
    }

    func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        let snapshot = lock.withLock {
            (
                fallbackIsActive,
                currentTargetId == targetId ? playbackFailure : nil,
                startedTargetId == targetId,
                pendingStartTargetId == targetId || pendingAutoplayOffset != nil || !inFlightOffsets.isEmpty,
                currentTargetId == targetId ? transportIntent : nil,
                currentTargetId == targetId ? player?.timeControlStatus : nil
            )
        }
        if snapshot.0 { return fallback.playbackStartStatus(targetId: targetId) }
        if let failure = snapshot.1 { return .failed(failure) }
        if observesPlayerLifecycle, snapshot.4 == .playing {
            switch snapshot.5 {
            case .playing:
                return .confirmed
            case .waitingToPlayAtSpecifiedRate, .paused, nil:
                return .pending
            @unknown default:
                return .pending
            }
        }
        if snapshot.2 { return .confirmed }
        return snapshot.3 ? .pending : .confirmed
    }

    /// True while the start waits for a chunk that is rendering and whose render deadline applies
    /// (the same condition that lets that deadline fall back to the iOS voice), so the engine's
    /// start watchdog doesn't fail a start that is only waiting on Supertonic (#235).
    func isAwaitingRenderedAudio(targetId: String) -> Bool {
        lock.withLock {
            guard !fallbackIsActive, currentTargetId == targetId, pendingStartTargetId == targetId,
                  transportIntent == .playing, playbackFailure == nil, !inFlightOffsets.isEmpty else { return false }
            if startedTargetId == nil { return true }
            return pendingAutoplayOffset.map(inFlightOffsets.contains) ?? false
        }
    }

    func pause() throws {
        interruptionWaitEnded(.listenerActed)
        let snapshot = lock.withLock { () -> (Bool, AVPlayer?) in
            transportIntent = .paused
            shouldResumeAfterInterruption = false
            handOverGaps.discardPending()
            return (fallbackIsActive, player)
        }
        if snapshot.0 {
            try fallback.pause()
        } else {
            snapshot.1?.pause()
            try releaseBackgroundAudio()
        }
    }

    func playbackTransportState(targetId: String) -> PlaybackTransportState? {
        let snapshot = lock.withLock {
            (fallbackIsActive, currentTargetId, transportIntent, playbackFailure, playbackComplete, player)
        }
        if snapshot.0 {
            return fallback.playbackTransportState(targetId: targetId) ?? (snapshot.2 == .paused ? .paused : .playing)
        }
        guard snapshot.1 == targetId else { return .stopped }
        if snapshot.3 != nil { return .failed }
        if snapshot.4 || snapshot.2 == .stopped { return .stopped }
        if snapshot.2 == .paused { return .paused }
        switch snapshot.5?.timeControlStatus {
        case .playing: return .playing
        case .waitingToPlayAtSpecifiedRate: return .waiting
        // A paused or temporarily absent AVPlayer is not a canonical pause
        // while the transport intent remains playing. This is the normal state
        // during the deliberate sentence-boundary delay and while the next
        // rendered chunk is being installed. Reporting `.paused` here stops the
        // app's canonical progress ticker; the delayed player then starts with
        // no observation capable of restoring the UI to playing.
        case .paused, nil: return .waiting
        @unknown default: return nil
        }
    }

    func stop() throws {
        interruptionWaitEnded(.listenerActed)
        removePlaybackEndObserver()
        defer { releaseHandOverBackgroundTimeIfHeld() }
        let stopped = lock.withLock { () -> (urls: [URL], renderControl: RenderTaskControl?) in
            generation = UUID()
            let renderControl = activeRenderControl
            activeRenderControl = nil
            player?.pause()
            Self.empty(player)
            player = nil
            fallbackIsActive = false
            let urls = Set(
                renderedCache.values.map(\.url)
                    + generationResults.values.map(\.audioURL)
                    + [activeAudioURL].compactMap { $0 }
            )
            activeAudioURL = nil
            activeAudioDuration = 0
            renderedCache.removeAll()
            inFlightOffsets.removeAll()
            pendingAutoplayOffset = nil
            completedTargetId = nil
            playbackComplete = false
            pendingStartTargetId = nil
            startedTargetId = nil
            playbackFailure = nil
            transportIntent = .stopped
            shouldResumeAfterInterruption = false
            handOverAwaitingStart = nil
            generationDisabledReasons.removeAll()
            resourceFallbackTargetIds.removeAll()
            generationPlan.removeAll()
            generationRenderOrder.removeAll()
            generationResults.removeAll()
            standInOffsets.removeAll()
            bundledVoiceOffsets.removeAll()
            initialPlaybackOffset = nil
            initialRequestedSpokenOffset = nil
            failedRenderReasons.removeAll()
            preparedAudioAssemblyStarted = false
            return (Array(urls), renderControl)
        }
        stopped.renderControl?.cancel()
        for url in stopped.urls { discardAudio(url) }
        try releaseBackgroundAudio()
        try fallback.stop()
        reportGenerationState(.inactive)
    }

    /// Stops scheduling on-device synthesis for the current item and keeps
    /// playback moving with the iOS system voice. The synchronous ONNX call
    /// already in progress cannot be interrupted, but its result is discarded
    /// and no following chunk is scheduled.
    /// `returnsAutomatically`: true for a memory warning, whose fallback ends by itself (I14);
    /// false when the listener chose to stop generation.
    @discardableResult
    func stopOnDeviceRenderingAndUseSystemSpeech(returnsAutomatically: Bool = false) throws -> Bool {
        let offset = currentCharOffset() ?? currentRecoveryCharOffset() ?? 0
        let state = lock.withLock { (currentTargetId, transportIntent, fallbackIsActive) }
        guard let targetId = state.0 else { return false }
        lock.withLock {
            if returnsAutomatically {
                resourceFallbackTargetIds.insert(targetId)
            } else {
                resourceFallbackTargetIds.remove(targetId)
            }
        }
        let stopReason = returnsAutomatically
            ? SpeechFallbackReason.memoryWarning.rawValue
            : SpeechFallbackReason.listenerStoppedGeneration.rawValue
        if state.2 {
            lock.withLock { generationDisabledReasons[targetId] = stopReason }
            reportGenerationState(.stopped, stopReason: stopReason)
            return true
        }

        _ = try fallback.prepareSpeechText(lock.withLock { preparedSourceText })
        let spokenOffset = spokenOffset(forSourceOffset: offset)
        removePlaybackEndObserver()
        let stopped = lock.withLock { () -> (urls: [URL], renderControl: RenderTaskControl?) in
            generation = UUID()
            let renderControl = activeRenderControl
            activeRenderControl = nil
            generationDisabledReasons[targetId] = stopReason
            player?.pause()
            Self.empty(player)
            player = nil
            let urls = Set(
                renderedCache.values.map(\.url)
                    + generationResults.values.map(\.audioURL)
                    + [activeAudioURL].compactMap { $0 }
            )
            activeAudioURL = nil
            activeAudioDuration = 0
            renderedCache.removeAll()
            inFlightOffsets.removeAll()
            pendingAutoplayOffset = nil
            pendingStartTargetId = targetId
            startedTargetId = nil
            playbackFailure = nil
            fallbackIsActive = true
            currentStartOffset = spokenOffset
            currentChunkLength = 0
            generationPlan.removeAll()
            generationRenderOrder.removeAll()
            generationResults.removeAll()
            standInOffsets.removeAll()
            bundledVoiceOffsets.removeAll()
            failedRenderReasons.removeAll()
            initialPlaybackOffset = nil
            initialRequestedSpokenOffset = nil
            preparedAudioAssemblyStarted = false
            shouldResumeAfterInterruption = false
            return (Array(urls), renderControl)
        }
        stopped.renderControl?.cancel()
        for url in stopped.urls { discardAudio(url) }

        try fallback.play(targetId: targetId, from: offset)
        if state.1 == .paused {
            try fallback.pause()
        }
        lock.withLock {
            systemVoicePlayback += 1
            pendingStartTargetId = nil
            startedTargetId = state.1 == .playing ? targetId : nil
            transportIntent = state.1
        }
        reportGenerationState(.stopped, stopReason: stopReason)
        if state.1 == .playing { startStallMonitorIfNeeded() }
        return true
    }

    /// Retry the current target at its current source offset, including while
    /// paused. Completed disk/manifest chunks remain eligible for reuse.
    func retryOnDeviceRendering() throws -> Bool {
        guard let target = lock.withLock({ currentTargetId }) else { return false }
        let offset = currentCharOffset() ?? 0
        let wasPaused = lock.withLock { transportIntent == .paused }
        try fallback.stop()
        lock.withLock {
            generationDisabledReasons.removeValue(forKey: target)
            resourceFallbackTargetIds.remove(target)
            fallbackIsActive = false
        }
        guard let request = nextRequest(targetId: target, fromSpokenOffset: spokenOffset(forSourceOffset: offset)) else { return false }
        enqueueRender(request, shouldPlayWhenReady: false)
        if wasPaused { try pause() }
        return true
    }

    private func playbackItemFinished(_ item: AVPlayerItem) {
        // The queue already moved on to the chunk behind this one, with no app code: catch the bookkeeping up. When
        // the item that ended is the chunk that was queued (the app was away through the whole of the one before),
        // its own end is handled below (#538).
        if applyQueuedAdvance(finished: item), lock.withLock({ activeItem !== item }) { return }
        guard lock.withLock({
            (player?.currentItem === item || (player != nil && activeItem === item)) && transportIntent == .playing
        }) else { return }
        removePlaybackEndObserver()
        let snapshot = lock.withLock { () -> (Int, String?, Int, CachedAudio?, TimeInterval, UUID, URL?, RenderedSpeechChunkBoundary) in
            // Set with the finished player detached, so the monitor never sees the old player as the next one.
            handOverHoldRequested = handOverHold != nil
            let nextOffset = currentStartOffset + max(1, currentChunkLength)
            // Commit audible progress before detaching the finished player.
            // During an underrun, timeout/fallback and pause/resume must start
            // at the next chunk, not repeat the passage that just finished.
            currentStartOffset = nextOffset
            currentChunkLength = 0
            let cached = cachedOrSavedChunk(containing: nextOffset)
            let finishedURL = activeAudioURL
            Self.empty(player)
            player = nil
            activeItem = nil
            activeAudioURL = nil
            activeAudioDuration = 0
            initialRequestedSpokenOffset = nil
            return (
                nextOffset,
                currentTargetId,
                preparedSpeechProjection.text.count,
                cached,
                currentChunkBoundary.transitionDelay,
                generation,
                finishedURL,
                currentChunkBoundary
            )
        }
        holdBackgroundTimeForHandOver()
        if let finishedURL = snapshot.6,
           !lock.withLock({ generationResults.values.contains(where: { $0.audioURL == finishedURL }) }) {
            discardAudio(finishedURL)
        }
        guard let targetId = snapshot.1,
              snapshot.0 < snapshot.2,
              let request = renderRequest(targetId: targetId, startOffset: snapshot.0, generation: snapshot.5) else {
            let stateAfterPlayback = lock.withLock { () -> (RenderedSpeechGenerationState, String?) in
                currentStartOffset = snapshot.2
                currentChunkLength = 0
                completedTargetId = snapshot.1
                playbackComplete = true
                transportIntent = .stopped
                if generationState == .ready || generationState == .stopped {
                    return (generationState, generationStopReason)
                }
                return (generationPlan.isEmpty ? .inactive : .rendering, nil)
            }
            // No chunk follows, so no hand-over is waiting for background time.
            releaseHandOverBackgroundTimeIfHeld()
            try? releaseBackgroundAudio()
            reportGenerationState(stateAfterPlayback.0, stopReason: stateAfterPlayback.1)
            return
        }
        lock.withLock {
            handOverGaps.chunkFinished(
                at: ProcessInfo.processInfo.systemUptime,
                generation: snapshot.5,
                boundary: snapshot.7,
                nextChunkWasReady: snapshot.3 != nil
            )
        }
        // A seam that came with the app away and was not a queued one: say why (#538).
        if let applicationIsActive, !applicationIsActive() {
            let isStandIn = lock.withLock { standInOffsets.contains(snapshot.0) }
            recordBackgroundSeam(BackgroundChunkSeam.missedOutcome(
                nextChunkIsRendered: snapshot.3 != nil, nextChunkIsStandIn: isStandIn
            ))
        }
        if let cached = snapshot.3 {
            playRenderedAudio(cached.url, duration: cached.duration, request: cached.request, delay: snapshot.4)
        } else if let reason = lock.withLock({ failedRenderReasons[snapshot.0] }) {
            activateSystemFallback(
                targetId: targetId,
                sourceOffset: sourceOffset(forSpokenOffset: snapshot.0),
                reason: reason
            )
        } else {
            try? releaseBackgroundAudio()
            let rendering = lock.withLock { () -> Bool in
                pendingAutoplayOffset = snapshot.0
                return inFlightOffsets.contains(snapshot.0)
            }
            // A normal render gap is a wait for the selected Supertonic voice,
            // never a reason to change voices. The serial full-item generation
            // pump will start this chunk as soon as it becomes available. If it
            // isn't rendering (a seek skipped past it, #346), render it now
            // rather than wait for a render that will never come.
            if !rendering { enqueueRender(request, shouldPlayWhenReady: false) }
        }
    }

    private func nextRequest(targetId: String, fromSpokenOffset spokenOffset: Int) -> RenderRequest? {
        removePlaybackEndObserver()
        let snapshot = lock.withLock { () -> (
            source: String,
            generation: UUID,
            urls: [URL],
            renderControl: RenderTaskControl?
        ) in
            let source = preparedSpeechProjection.text
            generation = UUID()
            let nextGeneration = generation
            let renderControl = activeRenderControl
            activeRenderControl = nil
            player?.pause()
            Self.empty(player)
            player = nil
            fallbackIsActive = false
            let urls = Set(
                renderedCache.values.map(\.url)
                    + generationResults.values.map(\.audioURL)
                    + [activeAudioURL].compactMap { $0 }
            )
            activeAudioURL = nil
            activeAudioDuration = 0
            renderedCache.removeAll()
            inFlightOffsets.removeAll()
            pendingAutoplayOffset = nil
            completedTargetId = nil
            playbackComplete = false
            pendingStartTargetId = targetId
            startedTargetId = nil
            playbackFailure = nil
            if currentTargetId != targetId { renderPace = RenderPaceLog() }
            currentTargetId = targetId
            activeSourceText = preparedSourceText
            currentStartOffset = max(0, min(spokenOffset, source.count))
            currentChunkLength = 0
            transportIntent = .playing
            generationPlan.removeAll()
            generationRenderOrder.removeAll()
            generationResults.removeAll()
            standInOffsets.removeAll()
            bundledVoiceOffsets.removeAll()
            failedRenderReasons.removeAll()
            preparedAudioAssemblyStarted = false
            return (source, nextGeneration, Array(urls), renderControl)
        }
        snapshot.renderControl?.cancel()
        for url in snapshot.urls { discardAudio(url) }
        let article = articleStart(targetId: targetId)
        let spokenPlan = NarrationChunkPlanner.spokenPlan(
            spokenText: snapshot.source, articleText: article.text, articleSpokenStart: article.spoken, budget: maxCharacters
        )
        lock.withLock {
            articleSpokenStart = spokenPlan.articleSpokenStart
            articleSourceStart = article.source
            // Without an article text, the spoken text is the article, identified by its source text.
            articleIdentity = spokenPlan.articleIdentity
                ?? (article.text == nil ? NarrationChunkPlanner.identity(ofArticle: preparedSourceText) : nil)
        }
        func requests(_ chunks: [NarrationChunkPlanner.SpokenChunk]) -> [RenderRequest] {
            chunks.map {
                RenderRequest(generation: snapshot.generation, targetId: targetId, startOffset: $0.startOffset,
                              sourceLength: $0.sourceLength, text: $0.text, boundary: $0.boundary, articleIndex: $0.articleIndex)
            }
        }
        let canonicalPlan = requests(spokenPlan.chunks)
        // Starting on the bundled voice (Supertonic isn't allowed): a short first chunk, so audio starts in about
        // a second. The article's own plan is unchanged (#849). The split is used only when the playhead is in its
        // first half, and the whole chunk is kept: when it has saved Supertonic audio, that plays instead (#849 audit).
        var plan = canonicalPlan
        var fastStartOriginal: RenderRequest?
        if pressureRenderer != nil, !onDeviceRenderingAllowed(),
           let original = canonicalPlan.last(where: {
               $0.startOffset <= spokenOffset && spokenOffset < $0.startOffset + max(1, $0.sourceLength)
           }) {
            let split = requests(NarrationChunkPlanner.splittingFirstChunk(
                of: spokenPlan.chunks, spokenText: snapshot.source, playheadOffset: spokenOffset))
            if let head = split.first(where: { $0.startOffset == original.startOffset }),
               head.sourceLength < original.sourceLength,
               spokenOffset < head.startOffset + head.sourceLength {
                plan = split
                fastStartOriginal = original
            }
        }
        guard !plan.isEmpty else { return nil }
        let playbackIndex = plan.lastIndex {
            $0.startOffset <= spokenOffset
                && spokenOffset < $0.startOffset + max(1, $0.sourceLength)
        } ?? max(0, plan.count - 1)
        let playbackRequest = plan[playbackIndex]
        let forward = Array(plan[playbackIndex...])
        lock.withLock {
            generationPlan = plan
            preparationPlan = canonicalPlan
            fastStartOriginals = fastStartOriginal.map { [$0.startOffset: $0] } ?? [:]
            // Navigation is also a demand signal. Render from the new playhead
            // forward and leave skipped material for an explicit offline job;
            // wrapping to the prefix keeps the model hot for audio the listener
            // just chose not to hear.
            generationRenderOrder = forward
            initialPlaybackOffset = playbackRequest.startOffset
            initialRequestedSpokenOffset = spokenOffset
            currentStartOffset = spokenOffset
        }
        reportGenerationProgress(completedChunks: 0, totalChunks: plan.count)
        return playbackRequest
    }

    /// The spoken and source offsets where the article starts, and the article's text, when the
    /// text being spoken is a preface followed by exactly that text. Zero and nil otherwise.
    private func articleStart(targetId: String) -> (spoken: Int, source: Int, text: String?) {
        guard let article = articleText?(targetId), !article.isEmpty else { return (0, 0, nil) }
        return lock.withLock {
            guard preparedSourceText.hasSuffix(article) else { return (0, 0, article) }
            let source = preparedSourceText.count - article.count
            return (preparedSpeechProjection.spokenCharacterOffset(atOrAfterSourceOffset: source), source, article)
        }
    }

    /// The saved Supertonic audio for the whole chunk a fallback play split for a quick start, when there is some
    /// (#849 audit): prepared audio first, then the disk cache, as for any chunk. On a hit the whole chunk takes the
    /// place of both halves in the plan, so the saved audio plays and the second half is not rendered.
    /// `bundledVoice` asks for the bundled voice's own saved stand-in instead (#1680): its prepared audio only, marked
    /// with its engine.
    private func savedAudioForUnsplitChunk(
        _ head: RenderRequest,
        bundledVoice: Bool = false
    ) async -> (request: RenderRequest, result: SupertonicNarrationResult)? {
        let lookup = bundledVoice ? bundledVoiceChunkLookup : preparedChunkLookup
        let known = lock.withLock { () -> (original: RenderRequest, identity: String?, articleStart: Int)? in
            guard generation == head.generation, let original = fastStartOriginals[head.startOffset],
                  original.generation == head.generation, original.sourceLength > head.sourceLength else { return nil }
            return (original, articleIdentity, articleSpokenStart)
        }
        guard let known else { return nil }
        let original = known.original
        var saved: SupertonicNarrationResult?
        if let identity = known.identity, let index = original.articleIndex, let lookup,
           let recovered = await lookup(original.targetId, identity, PreparedChunkPlan(
               index: index,
               startOffset: original.startOffset - known.articleStart,
               sourceLength: original.sourceLength,
               text: original.text
           )) {
            saved = SupertonicNarrationResult(
                audioURL: recovered.audioURL,
                duration: recovered.duration,
                sampleRate: 0,
                renderDuration: 0,
                sessionLoadCount: 0,
                engine: bundledVoice ? KittenNarrationRenderer.engine : SupertonicNarrationResult.supertonicEngine
            )
        } else if !bundledVoice, let cached = diskCache?.cachedAudio(
            text: original.text, voice: voice, language: "en", speed: 1.0, synthesisSteps: 8
        ) {
            saved = cached
        }
        guard let saved else { return nil }
        let adopted = lock.withLock { () -> Bool in
            guard generation == head.generation, fastStartOriginals.removeValue(forKey: head.startOffset) != nil else {
                return false
            }
            let tailStart = head.startOffset + head.sourceLength
            func unsplit(_ plan: [RenderRequest]) -> [RenderRequest] {
                plan.compactMap {
                    $0.startOffset == head.startOffset ? original : ($0.startOffset == tailStart ? nil : $0)
                }
            }
            generationPlan = unsplit(generationPlan)
            generationRenderOrder = unsplit(generationRenderOrder)
            return true
        }
        // Saved audio belongs to the disk cache or the prepared store, so a lost race deletes nothing.
        return adopted ? (original, saved) : nil
    }

    /// The prepared-audio plan entry for a chunk, in the article's own coordinates, and the
    /// article plan's identity; nil for a preface chunk or when no prepared audio can match (#258, #312).
    private func articleChunkPlan(for request: RenderRequest) -> (identity: String, plan: PreparedChunkPlan)? {
        lock.withLock {
            guard let identity = articleIdentity,
                  let planned = generationPlan.first(where: { $0.startOffset == request.startOffset }),
                  let index = planned.articleIndex else { return nil }
            return (identity, PreparedChunkPlan(
                index: index,
                startOffset: request.startOffset - articleSpokenStart,
                sourceLength: request.sourceLength,
                text: request.text
            ))
        }
    }

    private func renderRequest(
        targetId: String,
        startOffset: Int,
        generation: UUID,
        source: String? = nil
    ) -> RenderRequest? {
        if let planned = lock.withLock({ generationPlan.first(where: { $0.startOffset == startOffset }) }) {
            // The plan's own chunk, so a preface section never runs into the article (#258).
            return RenderRequest(
                generation: generation, targetId: targetId, startOffset: planned.startOffset,
                sourceLength: planned.sourceLength, text: planned.text, boundary: planned.boundary,
                articleIndex: planned.articleIndex
            )
        }
        let source = source ?? lock.withLock { preparedSpeechProjection.text }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let clampedOffset = max(0, min(startOffset, source.count))
        guard clampedOffset < source.count else { return nil }
        let slice = RenderedSpeechChunker.sourceSlice(
            from: source,
            startOffset: clampedOffset,
            maxCharacters: maxCharacters
        )
        guard !slice.text.isEmpty, slice.sourceLength > 0 else { return nil }
        return RenderRequest(
            generation: generation,
            targetId: targetId,
            startOffset: clampedOffset,
            sourceLength: slice.sourceLength,
            text: slice.text,
            boundary: slice.boundary
        )
    }

    private func enqueueRender(_ request: RenderRequest, shouldPlayWhenReady: Bool = true) {
        let control = RenderTaskControl()
        let shouldStart = lock.withLock { () -> Bool in
            if renderedCache[request.startOffset] != nil || inFlightOffsets.contains(request.startOffset) {
                return false
            }
            inFlightOffsets.insert(request.startOffset)
            activeRenderControl = control
            return true
        }
        guard shouldStart else { return }
        reportGenerationState(.rendering)
        let waitLimit = renderWaitLimit
        let pressureRenderer = pressureRenderer
        let task = Task { [weak self, renderer, voice, pressureRenderer] in
            // Each renderer deletes only the files it wrote and ignores the rest.
            let discard: @Sendable (URL) async -> Void = { url in
                await renderer.discardGeneratedAudio(at: url)
                await pressureRenderer?.discardGeneratedAudio(at: url)
            }
            let timeout = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: waitLimit) } catch { return }
                    guard let self else { return }
                    let demand = self.lock.withLock { () -> (current: Bool, waiting: Bool) in
                        (self.generation == request.generation && self.inFlightOffsets.contains(request.startOffset),
                         self.transportIntent == .playing && (shouldPlayWhenReady || self.pendingAutoplayOffset == request.startOffset || self.startedTargetId == nil))
                    }
                    guard demand.current else { return }
                    // Slow speculative work must not interrupt audible prepared
                    // audio. The deadline applies only when the listener waits.
                    guard demand.waiting else { continue }
                    self.renderFailed(request: request, shouldPlayWhenReady: shouldPlayWhenReady, reason: "supertonic_render_timeout")
                    return
                }
            }
            defer { timeout.cancel() }
            do {
                try Task.checkCancellation()
                let preparation = self?.lock.withLock { () -> (String, [PreparedChunkPlan], Bool) in
                    guard let self else { return ("", [], false) }
                    let needsPlan = self.onPreparationPlan != nil
                        && request.startOffset == self.generationRenderOrder.first?.startOffset
                    let start = self.articleSpokenStart
                    let plan = needsPlan ? self.preparationPlan.compactMap { part in
                        part.articleIndex.map {
                            PreparedChunkPlan(index: $0, startOffset: part.startOffset - start, sourceLength: part.sourceLength, text: part.text)
                        }
                    } : []
                    return (self.articleIdentity ?? "", plan, needsPlan && self.articleIdentity != nil)
                }
                if let preparation, preparation.2 {
                    await self?.onPreparationPlan?(request.targetId, preparation.0, preparation.1)
                }
                try Task.checkCancellation()
                var result: SupertonicNarrationResult
                var performedInference = false
                var renderWall: Duration?
                var ownsResult = false
                // A split head's whole chunk may have saved Supertonic audio; it plays in place of both halves.
                var chunk = request
                // Once the bundled voice holds this generation it renders every later chunk, so the voice stays the
                // same until a play releases it (#849 audit). Saved Supertonic audio takes over from it only as a
                // whole run from a seam, and the same rule holds while Supertonic may not render, so the voice never
                // bounces back and forth (#1680).
                let holdsBundledVoice = pressureRenderer != nil && self?.holdsBundledVoice(for: request.generation) == true
                let guardsVoice = pressureRenderer != nil && (holdsBundledVoice || self?.onDeviceRenderingAllowed() == false)
                let playsSavedSupertonic = guardsVoice ? await self?.choosesSavedSupertonicRun(for: request) == true : true
                let articleChunk = self?.articleChunkPlan(for: request)
                if playsSavedSupertonic, let unsplit = await self?.savedAudioForUnsplitChunk(request) {
                    chunk = unsplit.request
                    result = unsplit.result
                } else if playsSavedSupertonic, let articleChunk,
                   let recovered = await self?.preparedChunkLookup?(request.targetId, articleChunk.identity, articleChunk.plan) {
                    result = SupertonicNarrationResult(
                        audioURL: recovered.audioURL,
                        duration: recovered.duration,
                        sampleRate: 0,
                        renderDuration: 0,
                        sessionLoadCount: 0
                    )
                } else if playsSavedSupertonic, let cached = self?.diskCache?.cachedAudio(
                    text: request.text,
                    voice: voice,
                    language: "en",
                    speed: 1.0,
                    synthesisSteps: 8
                ) {
                    result = cached
                } else if guardsVoice, let saved = await self?.savedBundledVoiceAudio(for: request, articleChunk: articleChunk) {
                    // The bundled voice's own saved audio for these words: played, not rendered again, after a
                    // restart too (#1680). A split head plays the whole chunk's. Still a stand-in, so it holds back
                    // assembly as #363 intended.
                    self?.holdBundledVoice(for: request.generation)
                    chunk = saved.request
                    result = saved.result
                    self?.reportSavedBundledVoiceStart(request: saved.request)
                } else {
                    // Supertonic is not allowed now, or the bundled voice holds this generation: the bundled Kitten
                    // voice renders the chunk when there is one, otherwise the iOS voice takes the passage (#849).
                    let allowedNow = self?.onDeviceRenderingAllowed() != false
                    let usesPressureRenderer = pressureRenderer != nil && (!allowedNow || holdsBundledVoice)
                    guard allowedNow || usesPressureRenderer else {
                        await MainActor.run {
                            self?.renderFailed(request: request, shouldPlayWhenReady: shouldPlayWhenReady,
                                               reason: "supertonic_resource_pressure")
                        }
                        return
                    }
                    let renderStartedAt = ContinuousClock.now
                    let rendered: SupertonicNarrationResult
                    if usesPressureRenderer, let pressureRenderer {
                        self?.holdBundledVoice(for: request.generation)
                        rendered = try await pressureRenderer.render(text: request.text)
                    } else {
                        performedInference = true
                        rendered = try await renderer.render(
                            text: request.text,
                            voice: voice,
                            language: "en",
                            speed: 1.0,
                            synthesisSteps: 8
                        )
                    }
                    renderWall = ContinuousClock.now - renderStartedAt
                    // Only Supertonic's own audio is cached under its key. An iOS-voice stand-in
                    // isn't, so the next play renders Supertonic again and re-checks it (#311).
                    if rendered.engine == SupertonicNarrationResult.supertonicEngine,
                       let cache = self?.diskCache,
                       let retained = try? cache.store(
                            rendered,
                            text: request.text,
                            voice: voice,
                            language: "en",
                            speed: 1.0,
                            synthesisSteps: 8
                       ) {
                        // The cached copy is what plays. Deleting the temporary original runs on
                        // the renderer's serial queue, behind any other item's inference, so it
                        // must not hold back publishing the chunk (#235).
                        Task { await renderer.discardGeneratedAudio(at: rendered.audioURL) }
                        result = retained
                    } else {
                        result = rendered
                        ownsResult = true
                    }
                }
                if Task.isCancelled {
                    // An uncached render (a stand-in, or no disk cache) belongs to nothing else: a
                    // stop or seek during it must delete it, not leak it (#363 audit).
                    if ownsResult { let owned = result.audioURL; Task { await discard(owned) } }
                    throw CancellationError()
                }
                if performedInference, self?.onDeviceRenderingAllowed() == false, let pressureRenderer {
                    // The condition turned while Supertonic rendered: its chunk is let go and the bundled voice
                    // renders the text, so the queue keeps going on one steady voice (#849).
                    let letGo = result.audioURL
                    Task { await discard(letGo) }
                    self?.holdBundledVoice(for: request.generation)
                    let renderStartedAt = ContinuousClock.now
                    result = try await pressureRenderer.render(text: request.text)
                    renderWall = ContinuousClock.now - renderStartedAt
                    ownsResult = true
                    performedInference = false
                    if Task.isCancelled {
                        let cancelled = result.audioURL
                        Task { await discard(cancelled) }
                        throw CancellationError()
                    }
                }
                guard !performedInference || self?.onDeviceRenderingAllowed() != false else {
                    let refused = result.audioURL
                    Task { await discard(refused) }
                    await MainActor.run {
                        self?.renderFailed(
                            request: request,
                            shouldPlayWhenReady: shouldPlayWhenReady,
                            reason: "supertonic_resource_pressure"
                        )
                    }
                    return
                }
                if let renderWall {
                    self?.recordRenderPace(request: chunk, audioSeconds: result.duration, wall: renderWall)
                }
                await self?.renderCompleted(
                    result: result,
                    request: chunk,
                    shouldPlayWhenReady: shouldPlayWhenReady
                )
            } catch is CancellationError {
                await MainActor.run {
                    self?.renderCancelled(request: request)
                }
            } catch {
                await MainActor.run {
                    self?.renderFailed(
                        request: request,
                        shouldPlayWhenReady: shouldPlayWhenReady,
                        reason: "supertonic_render_failed:\(type(of: error))"
                    )
                }
            }
        }
        control.install(task)
    }

    private func renderCancelled(request: RenderRequest) {
        lock.withLock {
            guard generation == request.generation else { return }
            inFlightOffsets.remove(request.startOffset)
            if pendingAutoplayOffset == request.startOffset {
                pendingAutoplayOffset = nil
            }
        }
    }

    @MainActor
    private func renderCompleted(
        result: SupertonicNarrationResult,
        request: RenderRequest,
        shouldPlayWhenReady: Bool
    ) async {
        let action = lock.withLock { () -> (
            valid: Bool,
            autoplay: CachedAudio?,
            next: RenderRequest?,
            completedChunks: Int,
            totalChunks: Int,
            complete: Bool
        ) in
            guard generation == request.generation else { return (false, nil, nil, 0, 0, false) }
            inFlightOffsets.remove(request.startOffset)
            let cached = CachedAudio(url: result.audioURL, duration: result.duration, request: request)
            if result.engine == SupertonicNarrationResult.supertonicEngine {
                standInOffsets.remove(request.startOffset)
                bundledVoiceOffsets.remove(request.startOffset)
            } else {
                standInOffsets.insert(request.startOffset)
                if result.engine == KittenNarrationRenderer.engine {
                    bundledVoiceOffsets.insert(request.startOffset)
                } else {
                    bundledVoiceOffsets.remove(request.startOffset)
                }
            }
            generationResults[request.startOffset] = SupertonicPreparedChunk(
                startOffset: request.startOffset,
                sourceLength: request.sourceLength,
                text: request.text,
                boundary: request.boundary,
                audioURL: result.audioURL
            )
            renderedCache[request.startOffset] = cached

            var autoplay: CachedAudio?
            let waitsAtBoundary = pendingAutoplayOffset == request.startOffset
            if waitsAtBoundary && transportIntent == .playing {
                pendingAutoplayOffset = nil
                autoplay = renderedCache.removeValue(forKey: request.startOffset)
            } else if startedTargetId == nil,
                      transportIntent == .playing,
                      let initialPlaybackOffset,
                      initialPlaybackOffset == generationRenderOrder.first?.startOffset {
                let startupOffsets = generationRenderOrder
                    .prefix(min(startupBufferChunkCount, generationRenderOrder.count))
                    .map(\.startOffset)
                if startupOffsets.allSatisfy({ generationResults[$0] != nil }) {
                    autoplay = renderedCache.removeValue(forKey: initialPlaybackOffset)
                }
            }

            let next: RenderRequest?
            if let index = generationRenderOrder.firstIndex(where: { $0.startOffset == request.startOffset }),
               generationRenderOrder.indices.contains(index + 1) {
                next = generationRenderOrder[index + 1]
            } else {
                next = nil
            }
            let completedRenderOrderCount = generationRenderOrder.reduce(into: 0) { count, planned in
                if generationResults[planned.startOffset] != nil { count += 1 }
            }
            return (
                true,
                autoplay,
                next,
                completedRenderOrderCount,
                generationRenderOrder.count,
                completedRenderOrderCount == generationRenderOrder.count
            )
        }
        guard action.valid else {
            discardAudio(result.audioURL)
            return
        }
        if let autoplay = action.autoplay {
            playRenderedAudio(autoplay.url, duration: autoplay.duration, request: autoplay.request)
        }
        // The chunk may be the one behind the playing chunk, and the app may be away (#538).
        queueNextChunkIfWanted()
        if let articleChunk = articleChunkPlan(for: request) {
            await onPreparedChunk?(
                request.targetId,
                articleChunk.identity,
                articleChunk.plan,
                result.audioURL,
                Int((result.duration * 1_000).rounded()),
                result.engine
            )
        }
        guard lock.withLock({ generation == request.generation }) else { return }
        reportGenerationProgress(
            completedChunks: action.completedChunks,
            totalChunks: action.totalChunks
        )
        if let next = action.next {
            enqueueRender(next, shouldPlayWhenReady: false)
        }
        if action.complete {
            let hasCompleteSource = lock.withLock {
                generationResults.count == generationPlan.count
            }
            if hasCompleteSource {
                assemblePreparedAudioIfComplete(generation: request.generation)
            } else {
                reportGenerationState(.ready)
            }
        } else {
            reportGenerationState(.rendering)
        }
    }

    private func renderFailed(
        request: RenderRequest,
        shouldPlayWhenReady: Bool,
        reason: String
    ) {
        let outcome = lock.withLock { () -> (isCurrent: Bool, shouldFallback: Bool) in
            let isCurrent = generation == request.generation
            guard isCurrent else { return (false, false) }
            inFlightOffsets.remove(request.startOffset)
            let awaited = pendingAutoplayOffset == request.startOffset
            if awaited { pendingAutoplayOffset = nil }
            failedRenderReasons[request.startOffset] = reason
            return (
                true,
                transportIntent == .playing
                    && (shouldPlayWhenReady || awaited || startedTargetId == nil)
            )
        }
        guard outcome.isCurrent else { return }
        reportGenerationState(.stopped, stopReason: reason)
        guard outcome.shouldFallback else { return }
        let sourceOffset = currentCharOffset()
            ?? sourceOffset(forSpokenOffset: request.startOffset)
        activateSystemFallback(
            targetId: request.targetId,
            sourceOffset: sourceOffset,
            reason: reason
        )
    }

    private func activateSystemFallback(request: RenderRequest, reason: String) {
        activateSystemFallback(
            targetId: request.targetId,
            sourceOffset: sourceOffset(forSpokenOffset: request.startOffset),
            reason: reason
        )
    }

    /// Why a stalled player hands over to the iOS voice (`SpeechEngineSelection`: `playerStalled`).
    private static let stalledPlayerReason = "supertonic_player_stalled"

    private func activateSystemFallback(targetId: String, sourceOffset: Int, reason: String) {
        // A stalled player's chunk is kept until the iOS voice is really speaking. If it can't start, the
        // pause for a tap replays that chunk (#302) instead of rendering it again.
        let keepsChunk = reason == Self.stalledPlayerReason
        let source = lock.withLock { preparedSourceText }
        // The stop names why the iOS voice took over, so the player's line needs nothing else (#314).
        let stopReason = SpeechFallbackReason(
            supertonicCode: reason,
            resourceBlock: SpeechEnginePolicy.onDeviceRenderingBlock(SupertonicResourcePolicy.currentConditions())
        ).rawValue
        var cancelledRenderQueue = false
        do {
            _ = try fallback.prepareSpeechText(source)
            removePlaybackEndObserver()
            let stopped = lock.withLock { () -> (urls: [URL], renderControl: RenderTaskControl?, kept: URL?) in
                generation = UUID()
                let renderControl = activeRenderControl
                activeRenderControl = nil
                generationDisabledReasons[targetId] = stopReason
                if reason == "supertonic_resource_pressure" || reason == Self.stalledPlayerReason {
                    resourceFallbackTargetIds.insert(targetId)
                } else {
                    resourceFallbackTargetIds.remove(targetId)
                }
                if keepsChunk {
                    // Silent already; the player, its place and its chunk go once the iOS voice speaks.
                    player?.pause()
                } else {
                    player?.pause()
                    Self.empty(player)
                    player = nil
                }
                var urls = Set(
                    renderedCache.values.map(\.url)
                        + generationResults.values.map(\.audioURL)
                        + [activeAudioURL].compactMap { $0 }
                )
                let kept = keepsChunk ? activeAudioURL : nil
                if let kept { urls.remove(kept) }
                if !keepsChunk {
                    activeAudioURL = nil
                    activeAudioDuration = 0
                    initialPlaybackOffset = nil
                    initialRequestedSpokenOffset = nil
                }
                renderedCache.removeAll()
                inFlightOffsets.removeAll()
                pendingAutoplayOffset = nil
                if keepsChunk {
                    // The chosen voice may get the chunk back (a pause, a seek, a voice that never begins), so the
                    // article's plan stays on the new generation, with the render queue from the chunk after the
                    // kept one. Wiped, the chunks after it would each render in the silence after the one before (#540 audit).
                    let keptStart = currentStartOffset
                    generationPlan = Self.rebound(generationPlan, to: generation)
                    generationRenderOrder = Self.rebound(generationRenderOrder.filter { $0.startOffset > keptStart }, to: generation)
                } else {
                    generationPlan.removeAll()
                    generationRenderOrder.removeAll()
                }
                generationResults.removeAll()
                standInOffsets.removeAll()
            bundledVoiceOffsets.removeAll()
                failedRenderReasons.removeAll()
                preparedAudioAssemblyStarted = false
                // Another hand-over replaces one still waiting for its voice; its kept chunk is among `urls`.
                if !keepsChunk { handOverAwaitingStart = nil }
                return (Array(urls), renderControl, kept)
            }
            stopped.renderControl?.cancel()
            cancelledRenderQueue = true
            for url in stopped.urls { discardAudio(url) }
            try fallback.play(targetId: targetId, from: sourceOffset)
            let startStatus = fallback.playbackStartStatus(targetId: targetId)
            if keepsChunk, case .failed = startStatus { throw HandOverStartFailed() }
            let spokenOffset = spokenOffset(forSourceOffset: sourceOffset)
            let chunk = lock.withLock { (start: currentStartOffset, length: currentChunkLength) }
            lock.withLock {
                fallbackIsActive = true
                systemVoicePlayback += 1
                currentTargetId = targetId
                currentStartOffset = spokenOffset
                currentChunkLength = 0
                pendingStartTargetId = nil
                startedTargetId = targetId
                playbackFailure = nil
                transportIntent = .playing
            }
            if keepsChunk, startStatus != .confirmed {
                // `play` returns once the speech is queued. A voice that never begins would leave the listener in
                // silence with playback shown as playing, and the watchdog arms only after a voice has moved. The
                // stall monitor waits for the first word, or gives the listener the tap.
                lock.withLock {
                    handOverAwaitingStart = HandOverAwaitingStart(
                        targetId: targetId, sourceOffset: sourceOffset, reason: reason, stopReason: stopReason,
                        kept: stopped.kept, playback: systemVoicePlayback,
                        chunkStart: chunk.start, chunkLength: chunk.length
                    )
                }
                startStallMonitorIfNeeded()
                return
            }
            finishSystemFallback(
                targetId: targetId, sourceOffset: sourceOffset, reason: reason, stopReason: stopReason,
                kept: stopped.kept
            )
        } catch {
            if keepsChunk { try? fallback.stop() }
            lock.withLock {
                fallbackIsActive = false
                playbackFailure = "supertonic_and_system_fallback_failed"
                pendingStartTargetId = nil
                if keepsChunk {
                    // The chosen voice was never given up: the tap must not be sent to the voice that just failed.
                    generationDisabledReasons.removeValue(forKey: targetId)
                    resourceFallbackTargetIds.remove(targetId)
                }
            }
            if keepsChunk, cancelledRenderQueue { restartRenderQueueBehindKeptChunk() }
            try? releaseBackgroundAudio()
        }
    }

    private struct HandOverStartFailed: Error {}

    /// The iOS voice is speaking: a stalled player's chunk can go, and the app is told the voice changed.
    private func finishSystemFallback(targetId: String, sourceOffset: Int, reason: String, stopReason: String, kept: URL?) {
        if reason == Self.stalledPlayerReason {
            lock.withLock {
                Self.empty(player)
                player = nil
                activeAudioURL = nil
                activeAudioDuration = 0
                initialPlaybackOffset = nil
                initialRequestedSpokenOffset = nil
                // The iOS voice has the article now: the plan kept for a return that did not happen goes, as in any fallback.
                generationPlan.removeAll()
                generationRenderOrder.removeAll()
            }
            if let kept { discardAudio(kept) }
        }
        reportGenerationState(.stopped, stopReason: stopReason)
        startStallMonitorIfNeeded()
        onFallback?(reason, sourceOffset, targetId)
    }

    private func playRenderedAudio(
        _ audioURL: URL,
        duration: TimeInterval,
        request: RenderRequest,
        delay requestedDelay: TimeInterval = 0
    ) {
        let shouldPlay = lock.withLock {
            generation == request.generation && transportIntent == .playing
        }
        guard shouldPlay else {
            lock.withLock {
                renderedCache[request.startOffset] = CachedAudio(
                    url: audioURL,
                    duration: duration,
                    request: request
                )
            }
            return
        }
        // The first passage the iOS voice takes over from the chosen voice is introduced by a chime. The passage waits
        // for it, so its own clock and the offsets Margins anchor to don't move (#934).
        let cueLeadIn = lock.withLock { () -> TimeInterval in
            if voiceChangeCueGeneration != request.generation {
                voiceChangeCueGeneration = request.generation
                voiceChangeCueDecider = NarrationVoiceChangeCue()
            }
            return voiceChangeCueDecider.leadIn(forStandIn: isSystemVoiceStandIn(at: request.startOffset))
        }
        if cueLeadIn > 0, let voiceChangeCue { voiceChangeCue() }
        // I14: the first bundled-voice passage of a generation tells the listener why the voice changed (#849 audit).
        // Only while the bundled voice still holds the generation: a Kitten chunk that was still rendering when a play
        // released the voice must not announce it again, on a phone that has cooled (#849 audit).
        let bundledNotice = lock.withLock { () -> (announces: Bool, block: SpeechFallbackReason?) in
            guard bundledVoiceGeneration == request.generation,
                  bundledVoiceOffsets.contains(request.startOffset),
                  bundledVoiceNoticeGeneration != request.generation else { return (false, nil) }
            bundledVoiceNoticeGeneration = request.generation
            return (true, bundledVoiceBlock)
        }
        if bundledNotice.announces {
            onBundledVoice?(bundledNotice.block, sourceOffset(forSpokenOffset: request.startOffset), request.targetId)
        }
        let delay = requestedDelay + (voiceChangeCue == nil ? 0 : cueLeadIn)
        do {
            // Keep the session continuous between ready chunks so opted-in
            // background audio does not swell at each sentence boundary.
            if lock.withLock({ fallbackIsActive }) { try fallback.stop() }
            let level = lock.withLock { playbackVolume }
            let item = AVPlayerItem(url: audioURL)
            item.audioTimePitchAlgorithm = .timeDomain
            let nextPlayer: AVPlayer
            if applicationIsActive != nil, observesPlayerLifecycle {
                // A queue that acts like a single-item player (it stays on the item at its end) until a chunk is
                // queued behind it while the app is away (#538).
                let queue = AVQueuePlayer(items: [item])
                queue.actionAtItemEnd = .pause
                nextPlayer = queue
            } else {
                nextPlayer = AVPlayer(playerItem: item)
            }
            nextPlayer.volume = level
            rateChangeLock.withLock { lastRateChange = nil }
            if observesPlayerLifecycle {
                installPlaybackObservers(for: item, player: nextPlayer, request: request)
            }
            lock.withLock {
                player = nextPlayer
                activeItem = item
                queuedChunk = nil
                playerCreatedAt = ContinuousClock.now
                playerStartedAt = nil
                activeRequest = request
                activeAudioURL = audioURL
                activeAudioDuration = duration
                currentTargetId = request.targetId
                currentStartOffset = request.startOffset
                currentChunkLength = request.sourceLength
                currentChunkBoundary = request.boundary
                fallbackIsActive = false
                pendingStartTargetId = request.targetId
                startedTargetId = nil
                playbackFailure = nil
            }
            let initialSeek = lock.withLock { () -> TimeInterval? in
                guard request.startOffset == initialPlaybackOffset,
                      let requested = initialRequestedSpokenOffset,
                      requested > request.startOffset else { return nil }
                let fraction = Double(requested - request.startOffset) / Double(max(1, request.sourceLength))
                return max(0, min(duration, duration * fraction))
            }
            if let initialSeek {
                nextPlayer.seek(
                    to: CMTime(seconds: initialSeek, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            if delay > 0 {
                Task { @MainActor [weak self, weak nextPlayer, weak item] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let nextPlayer, let item else { return }
                    self?.startPlayer(nextPlayer, item: item, request: request)
                }
            } else {
                startPlayer(nextPlayer, item: item, request: request)
            }
            startStallMonitorIfNeeded()
        } catch {
            diskCache?.invalidate(audioURL)
            discardAudio(audioURL)
            activateSystemFallback(
                targetId: request.targetId,
                sourceOffset: currentCharOffset()
                    ?? sourceOffset(forSpokenOffset: request.startOffset),
                reason: "supertonic_playback_failed"
            )
        }
    }

    /// The player's own state for the playback heartbeat (#288).
    func playerDiagnostics() -> [String: String] {
        lock.withLock { AudioSessionDiagnostics.fields(for: fallbackIsActive ? nil : player) }
    }

    /// True while the iOS voice reads in place of the on-device one (#1109).
    var isSystemVoiceActive: Bool { lock.withLock { fallbackIsActive } }

    /// The client's own intent and voice, for every `playback.state` record, so a pause no request explains
    /// shows which part of the client set it (#1109).
    func narrationDiagnostics() -> [String: String] {
        lock.withLock {
            PlaybackDiagnosticFields.narration(
                intent: String(describing: transportIntent),
                systemVoiceActive: fallbackIsActive,
                standInPassage: standInOffsets.contains(currentStartOffset)
            )
        }
    }

    /// A chunk the iOS voice reads in place of the chosen voice. Call with `lock` held.
    private func isSystemVoiceStandIn(at offset: Int) -> Bool {
        standInOffsets.contains(offset) && !bundledVoiceOffsets.contains(offset)
    }

    /// The guard's replacement that is playing now (#306), not a render prepared ahead.
    /// Full-item fallbacks have their own reason; this notice is only for a temporary passage.
    var replacementVoiceTargetId: String? {
        lock.withLock {
            guard !fallbackIsActive, transportIntent == .playing, !playbackComplete,
                  player?.currentItem != nil, startedTargetId == currentTargetId,
                  isSystemVoiceStandIn(at: currentStartOffset),
                  !observesPlayerLifecycle || player?.timeControlStatus == .playing else { return nil }
            return currentTargetId
        }
    }

    /// Watches the player's clock while playback is intended. AVPlayer can report "playing" while
    /// nothing is heard (#288); a clock that stops moving for `stallThreshold` is logged with the
    /// session's and player's state, and the player is re-seated at the same point. If that doesn't
    /// bring the clock back, playback pauses at the listener's place, so the control shows Play and
    /// one tap resumes (#302). A wait at a chunk boundary (no player) isn't a stall: the render
    /// deadline covers it. When the iOS voice reads instead, its place in the text is the clock (#288).
    private func startStallMonitorIfNeeded() {
        let interval = stallSampleInterval
        let thresholdMs = Int(stallThreshold.components.seconds * 1_000
            + stallThreshold.components.attoseconds / 1_000_000_000_000_000)
        lock.withLock {
            guard stallMonitor == nil else { return }
            stallMonitor = Task { [weak self] in
                var detector = PlaybackStallDetector(thresholdMs: thresholdMs, minimumProgressMs: 100)
                // The detector reports a continuous stall once; while it lasts, recovery is retried
                // whenever the cooldown allows, so one skipped attempt can't leave it silent.
                var stallOngoing = false
                // Each player is watched from scratch: a re-seat or another item must not inherit a
                // stall (both start at clock zero). A re-seat that doesn't help stalls again anew.
                // Each play of the iOS voice is watched from scratch too (#432 audit).
                var watched = WatchedPlayback()
                // The iOS voice is watched only once it has moved by a word or so: a voice still
                // starting up, or one that reports its place only per utterance, isn't a stall.
                var systemVoicePlace: Int?
                var systemVoiceIsArmed = false
                var watchedVoicePlayback: Int?
                let start = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self else { return }
                    // The iOS voice has no player clock (#288). Its clock is the count of words it has
                    // started, which moves through a citation list that maps to one place in the
                    // text (#432 audit); a voice that can't count words uses its place in the text.
                    // Both are read on the main actor, where the synthesizer's callbacks move them.
                    var systemVoice: (place: Int?, countsWords: Bool, complete: Bool, playback: Int)?
                    if self.lock.withLock({ self.transportIntent == .playing && self.fallbackIsActive }) {
                        systemVoice = await MainActor.run { () -> (place: Int?, countsWords: Bool, complete: Bool, playback: Int) in
                            let (target, playback) = self.lock.withLock { (self.currentTargetId, self.systemVoicePlayback) }
                            let words = (self.fallback as? SpokenProgressReporting)?.spokenProgress()
                            return (words ?? self.fallback.currentCharOffset(), words != nil,
                                    target.map { self.fallback.isPlaybackComplete(targetId: $0) } ?? true, playback)
                        }
                    }
                    if let playback = systemVoice?.playback, playback != watchedVoicePlayback {
                        watchedVoicePlayback = playback
                        systemVoicePlace = nil
                        systemVoiceIsArmed = false
                    }
                    if let systemVoice, let place = systemVoice.place {
                        if let last = systemVoicePlace, place != last,
                           systemVoice.countsWords || abs(place - last) <= Self.systemVoiceWordStepLimit {
                            systemVoiceIsArmed = true
                        }
                        systemVoicePlace = place
                    } else {
                        systemVoicePlace = nil
                        systemVoiceIsArmed = false
                    }
                    let armed = systemVoiceIsArmed
                    // A queue that moved on by itself has a new chunk's time against the old chunk's start (#538).
                    self.applyQueuedAdvance(finished: nil)
                    let sample = self.lock.withLock { () -> (active: Bool, intends: Bool, clock: Int?, watched: WatchedPlayback) in
                        if self.fallbackIsActive {
                            let voice = WatchedPlayback(systemVoicePlayback: self.systemVoicePlayback)
                            guard armed, let systemVoice, systemVoice.playback == self.systemVoicePlayback,
                                  let place = systemVoice.place, !systemVoice.complete else {
                                return (self.transportIntent == .playing, false, nil, voice)
                            }
                            // One word or character counts as progress: the detector's unit is scaled to match.
                            return (self.transportIntent == .playing, self.transportIntent == .playing, place * 1_000, voice)
                        }
                        let intends = self.transportIntent == .playing && self.player != nil
                        let time = self.playerTime(self.player)
                        return (self.transportIntent == .playing, intends, self.currentStartOffset * 1_000_000 + Int(time * 1_000),
                                WatchedPlayback(player: self.player.map(ObjectIdentifier.init)))
                    }
                    if self.lock.withLock({ self.handOverHoldRequested }), self.handOverIsOver() {
                        self.releaseHandOverBackgroundTime()
                    }
                    if sample.watched != watched {
                        watched = sample.watched
                        detector.reset()
                        stallOngoing = false
                    }
                    let elapsed = ContinuousClock.now - start
                    let uptimeMs = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                    if let event = detector.observe(uptimeMs: uptimeMs, mediaTimeMs: sample.intends ? sample.clock : nil,
                                                    intendsToPlay: sample.intends) {
                        if case .stalled = event { stallOngoing = true } else { stallOngoing = false }
                        #if DEBUG
                        self.debugStallWillBeHandled?()
                        #endif
                        await MainActor.run { self.handleStallEvent(event, sampled: sample.watched) }
                    } else if stallOngoing, sample.intends {
                        #if DEBUG
                        self.debugStallWillBeHandled?()
                        #endif
                        await MainActor.run { self.pauseIfReseatDidNotHelp(sampled: sample.watched) }
                    }
                    if self.lock.withLock({ self.handOverAwaitingStart != nil }) {
                        await self.confirmHandOverStart()
                        detector.reset()
                        stallOngoing = false
                    }
                    if !sample.active {
                        #if DEBUG
                        self.debugStallMonitorWillExit?()
                        #endif
                        // A play can land between the sample and here; it saw this monitor and
                        // started none, so keep watching if playback is intended again (#301).
                        let stops = self.lock.withLock { () -> Bool in
                            guard self.transportIntent != .playing else { return false }
                            self.stallMonitor = nil
                            return true
                        }
                        if stops { return }
                        detector.reset()
                        stallOngoing = false
                    }
                }
            }
        }
    }

    /// The most the iOS voice's place in the text moves between two samples when it reports each
    /// word. A move this small shows word-by-word progress; a whole utterance is several times longer.
    private static let systemVoiceWordStepLimit = 120

    /// What a stall sample watched: the Supertonic player, or which play of the iOS voice.
    private struct WatchedPlayback: Equatable {
        var player: ObjectIdentifier?
        var systemVoicePlayback: Int?
    }

    /// True while the playback a stall sample saw is still the one playing. Between the sample and
    /// its handling on the main actor, the listener can switch items, or pause and play the iOS
    /// voice again; the stall is then stale.
    private func isStillPlaying(_ sampled: WatchedPlayback) -> Bool {
        lock.withLock {
            guard transportIntent == .playing, player.map(ObjectIdentifier.init) == sampled.player else { return false }
            return sampled.player != nil || (fallbackIsActive && sampled.systemVoicePlayback == systemVoicePlayback)
        }
    }

    @MainActor
    private func handleStallEvent(_ event: PlaybackStallDetector.Event, sampled: WatchedPlayback) {
        if case .stalled = event, !isStillPlaying(sampled) { return }
        let (player, usesSystemVoice) = lock.withLock { (self.player, fallbackIsActive) }
        var fields = AudioSessionDiagnostics.fields().merging(AudioSessionDiagnostics.fields(for: player)) { first, _ in first }
            .merging(stallContextFields(player: player)) { first, _ in first }
        if usesSystemVoice { fields["engine"] = "system_voice" }
        switch event {
        case .stalled(_, let forMs):
            fields["stalledMs"] = String(forMs)
            // A second stall inside the cooldown means the last re-seat didn't hold.
            guard claimStallRecovery() else { return pauseStalledPlayback(fields) }
            fields["recovery"] = usesSystemVoice ? "restart_system_voice" : "reseat_player"
            onStall?("supertonic.stall", fields)
            if usesSystemVoice {
                restartStalledSystemVoice()
            } else {
                reseatStalledPlayer()
            }
        case .ended(_, _, let stalledForMs):
            fields["stalledMs"] = String(stalledForMs)
            onStall?("supertonic.stall_ended", fields)
        }
    }

    /// True, and the cooldown restarts, when a recovery may run now.
    private func claimStallRecovery() -> Bool {
        lock.withLock {
            if let last = lastStallRecovery, ContinuousClock.now - last < stallRecoveryCooldown { return false }
            lastStallRecovery = .now
            return true
        }
    }

    /// A stall still going `stallThreshold` after its re-seat: the re-seat didn't help.
    @MainActor
    private func pauseIfReseatDidNotHelp(sampled: WatchedPlayback) {
        guard isStillPlaying(sampled) else { return }
        let due = lock.withLock { lastStallRecovery.map { ContinuousClock.now - $0 >= stallThreshold } ?? false }
        guard due else { return }
        let (player, usesSystemVoice) = lock.withLock { (self.player, fallbackIsActive) }
        var fields = AudioSessionDiagnostics.fields().merging(AudioSessionDiagnostics.fields(for: player)) { first, _ in first }
            .merging(stallContextFields(player: player)) { first, _ in first }
        if usesSystemVoice { fields["engine"] = "system_voice" }
        pauseStalledPlayback(fields)
    }

    /// Stops showing "playing" for a player that makes no progress (#302), when the iOS voice can't read on
    /// in its place (#540). As after a media-services reset, the player is released with the listener's
    /// place and chunk kept, and the app is told playback paused: the control shows Play, and one tap plays
    /// the chunk from that place in a new player with the session re-activated.
    @MainActor
    private func pauseStalledPlayback(_ fields: [String: String]) {
        if handOverStalledPlayerToSystemVoice(fields) { return }
        pauseForTap(fields)
    }

    /// The last resort: the player is released with the listener's place and chunk kept, and the control shows Play.
    @MainActor
    private func pauseForTap(_ fields: [String: String]) {
        var fields = fields
        fields["recovery"] = "paused_for_tap"
        onStall?("supertonic.stall_paused", fields)
        // The tap may land before this monitor samples the pause; it must start a fresh monitor
        // rather than inherit this stall and pause the new player too.
        let usesSystemVoice = lock.withLock { () -> Bool in
            stallMonitor?.cancel()
            stallMonitor = nil
            return fallbackIsActive
        }
        // The monitor would have given back the background time held for this chunk's hand-over; it is gone.
        releaseHandOverBackgroundTimeIfHeld()
        if usesSystemVoice {
            // The iOS voice keeps its place; the next play speaks from it with a new synthesizer.
            let paused = lock.withLock { () -> Bool in
                guard transportIntent == .playing else { return false }
                transportIntent = .paused
                shouldResumeAfterInterruption = false
                return true
            }
            guard paused else { return }
            try? fallback.pause()
            try? releaseBackgroundAudio()
            interruptionHandler?(.began)
            return
        }
        markMediaServicesReset()
        // A media-services reset has no session to release; a watchdog pause must stop lowering
        // other apps' audio, as a listener's pause does (#301 audit).
        try? releaseBackgroundAudio()
    }

    /// The iOS voice said "playing" while silent until the listener paused and played again (#288).
    /// That pause and play is the recovery: a new synthesizer speaks from the same place.
    @MainActor
    private func restartStalledSystemVoice() {
        guard let targetId = lock.withLock({ fallbackIsActive && transportIntent == .playing ? currentTargetId : nil }),
              let offset = fallback.currentCharOffset() else { return }
        try? activateAudioSession()
        try? fallback.pause()
        try? fallback.play(targetId: targetId, from: offset)
    }

    /// Re-activates the session and plays the same chunk from the same point in a new player.
    private func reseatStalledPlayer() {
        applyQueuedAdvance(finished: nil)
        let snapshot = lock.withLock { () -> (URL, TimeInterval, RenderRequest, TimeInterval)? in
            guard transportIntent == .playing, let request = activeRequest, let url = activeAudioURL else { return nil }
            let time = playerTime(player)
            player?.pause()
            Self.empty(player)
            player = nil
            let fraction = activeAudioDuration > 0 ? time / activeAudioDuration : 0
            // A player that stalls before its initial seek lands still reads zero: keep the place
            // asked for rather than replay text already heard (#301 audit, #235).
            let chunk = request.startOffset..<(request.startOffset + max(1, request.sourceLength))
            let requested = initialRequestedSpokenOffset.flatMap { chunk.contains($0) ? $0 : nil } ?? request.startOffset
            initialPlaybackOffset = request.startOffset
            initialRequestedSpokenOffset = max(requested, request.startOffset + Int((Double(request.sourceLength) * fraction).rounded(.down)))
            return (url, activeAudioDuration, request, time)
        }
        guard let (url, duration, request, _) = snapshot else { return }
        try? activateAudioSession()
        playRenderedAudio(url, duration: duration, request: request)
    }

    /// The re-seat didn't bring the sound back. Reading on in the iOS voice from the listener's place needs no
    /// tap, so it works with the phone locked in a pocket, where "paused, tap to play" is silence with nothing on
    /// screen to tap (#540). The chosen voice gets another try at the next play. Returns false, leaving the pause
    /// for a tap as the last resort, when the iOS voice can't start either.
    @MainActor
    private func handOverStalledPlayerToSystemVoice(_ fields: [String: String]) -> Bool {
        let target = lock.withLock { () -> String? in
            guard transportIntent == .playing, !fallbackIsActive else { return nil }
            return currentTargetId
        }
        guard let target else { return false }
        let offset = currentCharOffset() ?? currentRecoveryCharOffset() ?? 0
        var fields = fields
        fields["recovery"] = "hand_over_to_system_voice"
        fields["sourceOffset"] = String(offset)
        onStall?("supertonic.stall_handover", fields)
        activateSystemFallback(targetId: target, sourceOffset: offset, reason: Self.stalledPlayerReason)
        let (handedOver, awaitingStart) = lock.withLock { () -> (Bool, Bool) in
            handOverAwaitingStart?.stallFields = fields
            return (fallbackIsActive, handOverAwaitingStart != nil)
        }
        if handedOver {
            // While the voice has not begun, the background time stays held: the stall monitor ends the wait.
            if !awaitingStart { releaseHandOverBackgroundTimeIfHeld() }
        } else {
            fields["recovery"] = "hand_over_failed"
            onStall?("supertonic.stall_handover_failed", fields)
        }
        return handedOver
    }

    private enum HandOverVerdict { case waiting, spoke, returned, gaveUp, gone }

    /// Waits for the iOS voice that took over from a stalled player to say its first word, for as long as a
    /// Supertonic player gets to start moving. If it never does, the stall pauses for a tap (#540).
    private func confirmHandOverStart() async {
        let deadline = ContinuousClock.now + stallThreshold
        while !Task.isCancelled {
            let timedOut = ContinuousClock.now >= deadline
            if await MainActor.run(body: { self.settleHandOver(timedOut: timedOut) }) { return }
            try? await Task.sleep(for: min(stallSampleInterval, .milliseconds(250)))
        }
    }

    /// Decides what became of the waiting hand-over and ends the wait, in one main-actor operation: a seek or a
    /// pause can't land between the look at the voice and the change that follows it (#540 audit). True when
    /// nothing is waiting any more.
    @MainActor
    private func settleHandOver(timedOut: Bool) -> Bool {
        guard let looked = lock.withLock({ handOverAwaitingStart }) else { return true }
        let startStatus = fallback.playbackStartStatus(targetId: looked.targetId)
        let settled = lock.withLock { () -> (awaiting: HandOverAwaitingStart, verdict: HandOverVerdict, stopReason: String)? in
            guard let awaiting = handOverAwaitingStart, awaiting.playback == looked.playback else { return nil }
            let speaking = fallbackIsActive && currentTargetId == awaiting.targetId
                && systemVoicePlayback == awaiting.playback
            let verdict: HandOverVerdict
            if !speaking {
                // Not this hand-over's voice any more: the iOS voice was started again, or the chosen voice is back.
                verdict = fallbackIsActive ? .spoke : .gone
            } else if transportIntent != .playing {
                // The listener paused, or the system interrupted, before the voice said a word.
                verdict = .returned
            } else {
                switch startStatus {
                case .confirmed: verdict = .spoke
                case .failed: verdict = .gaveUp
                case .pending: verdict = timedOut ? .gaveUp : .waiting
                }
            }
            let stopReason = generationDisabledReasons[awaiting.targetId] ?? awaiting.stopReason
            if verdict != .waiting { endHandOverWait(awaiting, as: verdict) }
            return (awaiting, verdict, stopReason)
        }
        guard let settled else { return false }
        let awaiting = settled.awaiting
        switch settled.verdict {
        case .waiting:
            return false
        case .gone:
            return true
        case .spoke:
            finishSystemFallback(
                targetId: awaiting.targetId, sourceOffset: awaiting.sourceOffset, reason: awaiting.reason,
                stopReason: settled.stopReason, kept: awaiting.kept
            )
            releaseHandOverBackgroundTimeIfHeld()
        case .returned:
            returnToChosenVoice(releasesAudioSession: true)
        case .gaveUp:
            // The iOS voice never began: it is stopped, the chosen voice has its place and chunk back, and the
            // stall pauses for a tap as it did before the hand-over.
            try? fallback.stop()
            var fields = awaiting.stallFields
            fields["recovery"] = "hand_over_failed"
            onStall?("supertonic.stall_handover_failed", fields)
            pauseForTap(fields)
            restartRenderQueueBehindKeptChunk()
        }
        return true
    }

    /// Ends the wait for the iOS voice's first word. `returned` and `gaveUp` give the chosen voice back the place,
    /// chunk length and engine state it had before the hand-over; `spoke` leaves the iOS voice in charge. Caller
    /// holds `lock`.
    private func endHandOverWait(_ awaiting: HandOverAwaitingStart, as verdict: HandOverVerdict) {
        handOverAwaitingStart = nil
        guard verdict == .returned || verdict == .gaveUp else { return }
        fallbackIsActive = false
        currentStartOffset = awaiting.chunkStart
        currentChunkLength = awaiting.chunkLength
        // A later stop stays: the listener stopping generation, or a memory warning, which brings the chosen voice
        // back by itself once the memory is free and so keeps its restoration marker (#540 audit).
        if generationDisabledReasons[awaiting.targetId] == awaiting.stopReason {
            generationDisabledReasons.removeValue(forKey: awaiting.targetId)
            resourceFallbackTargetIds.remove(awaiting.targetId)
        }
    }

    /// The wait ended before the iOS voice spoke, and the chosen voice goes on: the voice that never began is
    /// stopped and the kept chunk goes back in the cache at its place, as after a media-services reset. The next
    /// play starts it in a new player that is watched for its end, rather than the player the hand-over left
    /// without one (#540 audit). The app isn't told of a pause: the listener's own pause or play ended the wait.
    private func returnToChosenVoice(releasesAudioSession: Bool) {
        try? fallback.stop()
        markMediaServicesReset(announcesPause: false)
        if releasesAudioSession { try? releaseBackgroundAudio() }
        releaseHandOverBackgroundTimeIfHeld()
        restartRenderQueueBehindKeptChunk()
    }

    /// The hand-over cancelled the render queue behind the chunk it kept. With the chunk back, the queue starts again
    /// from the chunk after it, so that one is ready when this one ends instead of rendering in the silence after it.
    /// Nothing starts while the chosen voice may not render, or after the listener or a memory warning stopped
    /// generation during the wait; the next play finds its own way then (#540 audit). The queue is held for
    /// `restoreOnDeviceRenderingIfConditionCleared`, which starts it when a memory warning's stop lifts.
    private func restartRenderQueueBehindKeptChunk() {
        let renderingAllowed = onDeviceRenderingAllowed()
        let next = lock.withLock { () -> RenderRequest? in
            guard let next = generationRenderOrder.first else { return nil }
            guard renderingAllowed, generationDisabledReasons[next.targetId] == nil else {
                heldRenderQueueGeneration = generation
                return nil
            }
            heldRenderQueueGeneration = nil
            return next
        }
        if let next { enqueueRender(next, shouldPlayWhenReady: false) }
    }

    private static func rebound(_ requests: [RenderRequest], to generation: UUID) -> [RenderRequest] {
        requests.map { request in
            var request = request
            request.generation = generation
            return request
        }
    }

    /// A play, seek or next-item request that lands while a hand-over still waits for the voice's first word
    /// ends the wait before anything else moves. The chosen voice comes back with this play, as after any
    /// hand-over, unless it may not render now; then the iOS voice stays and the stalled chunk is let go.
    private func settleHandOverBeforePlay() {
        guard lock.withLock({ handOverAwaitingStart != nil }) else { return }
        let returns = onDeviceRenderingAllowed()
        let ended = lock.withLock { () -> (awaiting: HandOverAwaitingStart, stopReason: String)? in
            guard let awaiting = handOverAwaitingStart else { return nil }
            let stopReason = generationDisabledReasons[awaiting.targetId] ?? awaiting.stopReason
            endHandOverWait(awaiting, as: returns ? .returned : .spoke)
            return (awaiting, stopReason)
        }
        guard let ended else { return }
        if returns {
            returnToChosenVoice(releasesAudioSession: false)
        } else {
            let awaiting = ended.awaiting
            finishSystemFallback(
                targetId: awaiting.targetId, sourceOffset: awaiting.sourceOffset, reason: awaiting.reason,
                stopReason: ended.stopReason, kept: awaiting.kept
            )
            releaseHandOverBackgroundTimeIfHeld()
        }
    }

    /// What the stalled player's short life looked like, so an export says why it never made sound (#540):
    /// whether its start was asked for, what the system last did to its rate, what the app and the phone were
    /// doing, and what the chunk was. Text never goes in.
    @MainActor
    private func stallContextFields(player: AVPlayer?) -> [String: String] {
        let now = ContinuousClock.now
        func ms(_ duration: Duration) -> String { String(Self.milliseconds(duration)) }
        let snapshot = lock.withLock {
            (created: playerCreatedAt, started: playerStartedAt,
             standIn: standInOffsets.contains(currentStartOffset), audioSeconds: activeAudioDuration)
        }
        let lastChange = rateChangeLock.withLock { lastRateChange }
        let playerAge: String = snapshot.created.map { ms(now - $0) } ?? "none"
        let startAgo: String = snapshot.started.map { ms(now - $0) } ?? "never"
        let chunkAudio = String(Int((snapshot.audioSeconds * 1_000).rounded()))
        var fields: [String: String] = [
            "appState": Self.applicationStateName(),
            "conditions": SupertonicResourcePolicy.currentConditions().logDescription,
            "chunkEngine": snapshot.standIn ? "system_voice" : "supertonic",
            "chunkAudioMs": chunkAudio,
            "playerAgeMs": playerAge,
            "startRequestedAgoMs": startAgo
        ]
        if let change = lastChange {
            fields["lastRateChange"] = "\(change.reason) to \(String(format: "%.2f", change.rate))"
            fields["lastRateChangeAgoMs"] = ms(now - change.at)
        }
        if let item = player?.currentItem {
            let seconds = item.duration.seconds
            fields["itemDurationMs"] = seconds.isFinite ? String(Int((seconds * 1_000).rounded())) : "unknown"
            if let error = item.error as NSError? { fields["itemError"] = "\(error.domain):\(error.code)" }
        }
        return fields
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Keeps how fast a chunk rendered against how fast it plays, and reports the log's summary (#540).
    private func recordRenderPace(request: RenderRequest, audioSeconds: TimeInterval, wall: Duration) {
        let conditions = SupertonicResourcePolicy.currentConditions()
        let summary = lock.withLock { () -> String? in
            let sample = RenderPaceLog.Sample(
                chunkStartOffset: request.startOffset,
                renderSeconds: Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18,
                audioSeconds: audioSeconds,
                playbackRate: Double(playbackRate),
                isLowPowerModeEnabled: conditions.isLowPowerModeEnabled,
                thermal: conditions.thermal
            )
            return renderPace.record(sample) ? renderPace.summary : nil
        }
        if let summary { onRenderPace?(summary) }
    }

    /// A chunk ended and another follows: hold background time until the next is heard moving (#540). The
    /// player's callbacks arrive on the main thread; anything else hops there.
    private func holdBackgroundTimeForHandOver() {
        guard let hold = handOverHold else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { hold.chunkEnded() }
        } else {
            Task { @MainActor in hold.chunkEnded() }
        }
    }

    /// Gives the hold back if one is out. For the paths that end the monitor, which would otherwise release it.
    private func releaseHandOverBackgroundTimeIfHeld() {
        if lock.withLock({ handOverHoldRequested }) { releaseHandOverBackgroundTime() }
    }

    private func releaseHandOverBackgroundTime() {
        guard let hold = handOverHold else { return }
        lock.withLock { handOverHoldRequested = false }
        if Thread.isMainThread {
            MainActor.assumeIsolated { hold.nextChunkMoving() }
        } else {
            Task { @MainActor in hold.nextChunkMoving() }
        }
    }

    /// True once the chunk after a hand-over is heard moving, or nothing is waiting to play any more:
    /// playback paused or stopped, or the iOS voice took over.
    private func handOverIsOver() -> Bool {
        lock.withLock {
            guard transportIntent == .playing else { return true }
            if handOverAwaitingStart != nil { return false }
            guard !fallbackIsActive else { return true }
            guard let current = player else { return false }
            return current.rate > 0 && playerTime(current) >= 0.1
        }
    }

    private func assemblePreparedAudioIfComplete(generation expectedGeneration: UUID) {
        let snapshot = lock.withLock { () -> (
            targetId: String,
            sourceText: String,
            projection: NormalizedSpeechText,
            chunks: [SupertonicPreparedChunk]
        )? in
            guard generation == expectedGeneration,
                  !preparedAudioAssemblyStarted,
                  !generationPlan.isEmpty,
                  generationResults.count == generationPlan.count,
                  let targetId = generationPlan.first?.targetId else { return nil }
            preparedAudioAssemblyStarted = true
            return (
                targetId,
                preparedSourceText,
                preparedSpeechProjection,
                generationPlan.compactMap { generationResults[$0.startOffset] }
            )
        }
        guard let snapshot else { return }
        // Every chunk is ready, but one is a stand-in: report it, without an assembled file (#363).
        guard let preparedAudioDirectory, let onPreparedAudio, lock.withLock({ standInOffsets.isEmpty }) else {
            reportGenerationState(.ready)
            return
        }
        let voice = voice
        Task.detached(priority: .utility) { [weak self] in
            do {
                let prepared = try await SupertonicPreparedAudioAssembler.assemble(
                    itemId: snapshot.targetId,
                    sourceText: snapshot.sourceText,
                    projection: snapshot.projection,
                    voice: voice,
                    chunks: snapshot.chunks,
                    outputDirectory: preparedAudioDirectory
                )
                onPreparedAudio(snapshot.targetId, prepared)
                if self?.lock.withLock({ self?.generation == expectedGeneration }) == true {
                    self?.reportGenerationState(.ready)
                }
            } catch {
                if self?.lock.withLock({ self?.generation == expectedGeneration }) == true {
                    self?.reportGenerationState(.stopped, stopReason: SpeechGenerationStopReason.assemblyFailed(error))
                }
            }
        }
    }

    private func reportGenerationState(_ state: RenderedSpeechGenerationState, stopReason: String? = nil) {
        let stopReason = state == .stopped ? stopReason : nil
        lock.withLock {
            generationState = state
            generationStopReason = stopReason
        }
        onGenerationStateChange?(state, stopReason)
    }

    private func reportGenerationProgress(completedChunks: Int, totalChunks: Int) {
        onGenerationProgress?(RenderedSpeechGenerationProgress(
            completedChunks: completedChunks,
            totalChunks: totalChunks
        ))
    }

    private func startPlayer(_ nextPlayer: AVPlayer, item: AVPlayerItem, request: RenderRequest) {
        let rate = lock.withLock { () -> Float? in
            guard generation == request.generation,
                  transportIntent == .playing,
                  player === nextPlayer,
                  nextPlayer.currentItem === item else { return nil }
            pendingStartTargetId = nil
            startedTargetId = request.targetId
            playerStartedAt = ContinuousClock.now
            return playbackRate
        }
        guard let rate else { return }
        do {
            try activateAudioSession()
        } catch {
            activateSystemFallback(request: request, reason: "supertonic_playback_failed")
            return
        }
        let longestGap = lock.withLock {
            handOverGaps.chunkStarted(at: ProcessInfo.processInfo.systemUptime, generation: request.generation)
        }
        if let longestGap { onChunkHandOverGap?(longestGap) }
        if let audioPlayerStarter {
            audioPlayerStarter(nextPlayer, rate)
        } else {
            nextPlayer.playImmediately(atRate: rate)
        }
        queueNextChunkIfWanted()
    }

    private func discardAudio(_ url: URL) {
        if diskCache?.owns(url) == true { return }
        Task { await discardGeneratedAudio(at: url) }
    }

    /// Each renderer deletes only the files it wrote and ignores the rest.
    private func discardGeneratedAudio(at url: URL) async {
        await renderer.discardGeneratedAudio(at: url)
        await pressureRenderer?.discardGeneratedAudio(at: url)
    }

    private func resumeAction(targetId: String, fromSpokenOffset spokenOffset: Int, isSeek: Bool) -> ResumeAction {
        lock.withLock {
            // A play on narration that's already playing (a rate change restarts from the synced
            // position; a second Lock Screen play) reuses the live audio like a resume does,
            // rather than throwing it away and rendering again (#303).
            let wasPlaying = transportIntent == .playing
            guard transportIntent == .paused || wasPlaying,
                  currentTargetId == targetId,
                  activeSourceText == preparedSourceText else { return .none }
            let chunkEnd = currentStartOffset + max(0, currentChunkLength)
            if let player, spokenOffset >= currentStartOffset, spokenOffset <= chunkEnd {
                transportIntent = .playing
                pendingStartTargetId = nil
                startedTargetId = targetId
                let currentOffset = currentStartOffset + Int(
                    (Double(currentChunkLength) * max(0, min(1, playerTime(player) / max(activeAudioDuration, 0.001)))).rounded(.down)
                )
                // While playing, the requested position was sampled a moment ago and lags the live
                // one by a few characters; that's the same place, not a seek.
                // An explicit choice of this chunk: no other chunk may autoplay over it later.
                pendingAutoplayOffset = nil
                if abs(currentOffset - spokenOffset) <= (wasPlaying && !isSeek ? Self.livePositionTolerance : 1) {
                    // The player's own clock is the position now, not an earlier request for
                    // another chunk (#346 re-audit).
                    initialRequestedSpokenOffset = nil
                    return .resumePlayer(player)
                }
                initialRequestedSpokenOffset = spokenOffset
                let fraction = Double(spokenOffset - currentStartOffset) / Double(max(1, currentChunkLength))
                return .seekPlayer(player, max(0, min(activeAudioDuration, activeAudioDuration * fraction)))
            }
            if wasPlaying, let player {
                // Moving to another chunk: stop the live one first so two never play at once.
                player.pause()
                Self.empty(player)
                self.player = nil
            }
            if let cached = cachedOrSavedChunk(containing: spokenOffset) {
                transportIntent = .playing
                pendingStartTargetId = targetId
                // The listener chose this chunk; a marker left for another must not play over it.
                pendingAutoplayOffset = nil
                initialPlaybackOffset = cached.request.startOffset
                initialRequestedSpokenOffset = spokenOffset
                return .playCached(cached)
            }
            if let inFlight = generationPlan.first(where: {
                inFlightOffsets.contains($0.startOffset)
                    && spokenOffset >= $0.startOffset
                    && spokenOffset < $0.startOffset + max(1, $0.sourceLength)
            }) {
                transportIntent = .playing
                pendingStartTargetId = targetId
                initialPlaybackOffset = inFlight.startOffset
                initialRequestedSpokenOffset = spokenOffset
                // The finished render must play, and the render deadline must cover the wait.
                pendingAutoplayOffset = inFlight.startOffset
                return .awaitPendingRender
            }
            // Waiting at a boundary for a chunk that is planned but not yet rendering (for example
            // while the previous chunk is still being saved): render it rather than restart the
            // whole generation, and let the boundary marker play it (#235, Codex rank 3).
            if let waitingOffset = pendingAutoplayOffset,
               let planned = generationPlan.first(where: {
                   $0.startOffset == waitingOffset
                       && spokenOffset >= $0.startOffset
                       && spokenOffset < $0.startOffset + max(1, $0.sourceLength)
               }),
               failedRenderReasons[planned.startOffset] == nil {
                transportIntent = .playing
                pendingStartTargetId = targetId
                initialPlaybackOffset = planned.startOffset
                initialRequestedSpokenOffset = spokenOffset
                return .renderPlanned(planned)
            }
            return .none
        }
    }

    /// The spoken offset to resume at. An expansion such as " citation 1 " maps every spoken
    /// character to one source offset, so a position saved in its later part maps back to its
    /// first part. When a chunk boundary splits the expansion, that lands in the chunk already
    /// played, and the resume restarted rendering. Resume at the current chunk instead (#235,
    /// Codex rank 2).
    private func resumeSpokenOffset(targetId: String, sourceOffset: Int) -> Int {
        lock.withLock {
            let first = preparedSpeechProjection.spokenCharacterOffset(atOrAfterSourceOffset: sourceOffset)
            guard currentTargetId == targetId, first < currentStartOffset,
                  preparedSpeechProjection.sourceOffset(atSpokenCharacterOffset: currentStartOffset) == sourceOffset else {
                return first
            }
            return currentStartOffset
        }
    }

    /// The client's state when a play request arrives, before `resumeAction` changes it. The next
    /// device export then says why a resume restarted rendering or waited (#235).
    private func resumeDiagnostics(targetId: String, spokenOffset: Int) -> [String: String] {
        lock.withLock {
            let chunkState: String
            if renderedCache.values.contains(where: {
                spokenOffset >= $0.request.startOffset && spokenOffset < $0.request.startOffset + max(1, $0.request.sourceLength)
            }) {
                chunkState = "rendered"
            } else if generationPlan.contains(where: {
                inFlightOffsets.contains($0.startOffset)
                    && spokenOffset >= $0.startOffset && spokenOffset < $0.startOffset + max(1, $0.sourceLength)
            }) {
                chunkState = "rendering"
            } else {
                chunkState = "not_rendered"
            }
            return [
                "intent": String(describing: transportIntent),
                "sameTarget": String(currentTargetId == targetId),
                "sameText": String(activeSourceText == preparedSourceText),
                "hasPlayer": String(player != nil),
                "inPlayerChunk": String(player != nil && spokenOffset >= currentStartOffset
                    && spokenOffset <= currentStartOffset + max(0, currentChunkLength)),
                "offsetFromChunk": String(spokenOffset - currentStartOffset),
                "chunk": chunkState,
                "autoplayMarked": String(pendingAutoplayOffset != nil),
                "cached": String(renderedCache.count),
                "inFlight": String(inFlightOffsets.count),
                "started": String(startedTargetId == targetId)
            ]
        }
    }

    private func reportResumeDecision(_ action: ResumeAction, before: [String: String]) {
        guard let onResumeDecision else { return }
        var fields = before
        switch action {
        case .resumePlayer: fields["path"] = "resume_player"
        case .seekPlayer: fields["path"] = "seek_player"
        case .playCached: fields["path"] = "play_cached"
        case .awaitPendingRender: fields["path"] = "await_render"
        case .renderPlanned: fields["path"] = "render_planned"
        case .none: fields["path"] = "restart_rendering"
        }
        onResumeDecision(fields)
    }

    /// The chunk covering `spokenOffset`: from the rendered cache (taking it out, as before), or
    /// else this generation's saved result for it. Playing a cached chunk removes it from the
    /// cache, so after a seek ahead and back, a chunk already played is found here (#346).
    /// Call with the lock held.
    private func cachedOrSavedChunk(containing spokenOffset: Int) -> CachedAudio? {
        if let entry = renderedCache.first(where: { entry in
            spokenOffset >= entry.value.request.startOffset
                && spokenOffset < entry.value.request.startOffset + max(1, entry.value.request.sourceLength)
        }), let cached = renderedCache.removeValue(forKey: entry.key) {
            return cached
        }
        guard let planned = generationPlan.first(where: {
            spokenOffset >= $0.startOffset && spokenOffset < $0.startOffset + max(1, $0.sourceLength)
        }), let saved = generationResults[planned.startOffset],
              FileManager.default.fileExists(atPath: saved.audioURL.path) else { return nil }
        let file = try? AVAudioFile(forReading: saved.audioURL)
        let duration = file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        return CachedAudio(url: saved.audioURL, duration: duration, request: planned)
    }

    /// About two seconds of speech: how far a sampled position can trail the live one.
    static let livePositionTolerance = 30

    private func playerTime(_ player: AVPlayer?) -> TimeInterval {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    private func spokenOffset(forSourceOffset sourceOffset: Int) -> Int {
        lock.withLock {
            preparedSpeechProjection.spokenCharacterOffset(atOrAfterSourceOffset: sourceOffset)
        }
    }

    private func sourceOffset(forSpokenOffset spokenOffset: Int) -> Int {
        lock.withLock {
            preparedSpeechProjection.sourceOffset(atSpokenCharacterOffset: spokenOffset)
        }
    }

    private func installPlaybackObservers(for item: AVPlayerItem, player: AVPlayer, request: RenderRequest) {
        removePlaybackEndObserver()
        // The system's reason each time this player's rate changes: an interruption, a refused start, a
        // play call. A stalled player's export then says whether anything stopped it (#540).
        rateChangeObserver = NotificationCenter.default.addObserver(
            forName: AVPlayer.rateDidChangeNotification, object: player, queue: nil
        ) { [weak self] notification in
            guard let self, let changed = notification.object as? AVPlayer else { return }
            let reason = ((notification.userInfo?[AVPlayer.rateDidChangeReasonKey] as? String) ?? "none")
                .replacingOccurrences(of: "AVPlayerRateDidChangeReason", with: "")
            let rate = changed.rate
            self.rateChangeLock.withLock { self.lastRateChange = (reason, rate, ContinuousClock.now) }
        }
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let item else { return }
            self?.playbackItemFinished(item)
        }
        playerItemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            guard observedItem.status == .failed else { return }
            Task { @MainActor [weak self, weak observedItem] in
                guard let observedItem else { return }
                self?.playbackItemFailed(observedItem, request: request)
            }
        }
    }

    private func removePlaybackEndObserver() {
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        if let rateChangeObserver {
            NotificationCenter.default.removeObserver(rateChangeObserver)
            self.rateChangeObserver = nil
        }
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }
        dropQueuedChunk()
    }

    /// Takes the queued chunk's observers off and forgets it. Its player is being discarded, or its end is handled.
    private func dropQueuedChunk() {
        let dropped = lock.withLock { () -> (NSObjectProtocol?, NSKeyValueObservation?) in
            let observers = (queuedEndObserver, queuedStatusObservation)
            queuedEndObserver = nil
            queuedStatusObservation = nil
            queuedChunk = nil
            return observers
        }
        if let endObserver = dropped.0 { NotificationCenter.default.removeObserver(endObserver) }
        dropped.1?.invalidate()
    }

    /// Takes everything off a player that is being let go. A queue player also drops the chunks queued behind its
    /// current one, so none of them can start playing after the player is dropped (#538).
    private static func empty(_ player: AVPlayer?) {
        (player as? AVQueuePlayer)?.removeAllItems()
        player?.replaceCurrentItem(with: nil)
    }

    /// Leaving the app is when a queued chunk matters: the chunk behind the playing one may already be rendered.
    private func installLifecycleObservers() {
        #if canImport(UIKit) && os(iOS)
        guard applicationIsActive != nil, observesPlayerLifecycle else { return }
        lifecycleObservers.append(audioSessionNotificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.queueNextChunkIfWanted() })
        #endif
    }

    /// While the app is away, puts the next rendered chunk on the player behind the playing one, so the seam between
    /// them needs no app code and a backgrounded app that iOS suspends in a silent gap can't stall there (#538).
    /// Runs wherever the answer can change: a chunk starts, a render lands, the app leaves the front, a queued chunk
    /// becomes the playing one. It does nothing when there is nothing to queue.
    private func queueNextChunkIfWanted() {
        guard let applicationIsActive, observesPlayerLifecycle else { return }
        let appIsActive = applicationIsActive()
        lock.withLock {
            guard !appIsActive, let queue = player as? AVQueuePlayer, let playing = activeItem,
                  queue.currentItem === playing else { return }
            let nextOffset = currentStartOffset + max(1, currentChunkLength)
            let nextCached = renderedCache[nextOffset]
            let facts = BackgroundChunkSeam.Facts(
                appIsActive: appIsActive,
                intendsToPlay: transportIntent == .playing && !fallbackIsActive && handOverAwaitingStart == nil,
                nextChunkExists: nextOffset < preparedSpeechProjection.text.count,
                nextChunkIsRendered: nextCached != nil,
                nextChunkIsStandIn: standInOffsets.contains(nextOffset),
                alreadyQueued: queuedChunk != nil
            )
            guard BackgroundChunkSeam.shouldQueueAhead(facts), let cached = nextCached,
                  cached.request.generation == generation,
                  cached.request.targetId == currentTargetId else { return }
            let item = AVPlayerItem(url: cached.url)
            item.audioTimePitchAlgorithm = .timeDomain
            guard queue.canInsert(item, after: nil) else { return }
            let request = cached.request
            queuedEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self, weak item] _ in
                guard let item else { return }
                self?.playbackItemFinished(item)
            }
            queuedStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                guard observed.status == .failed else { return }
                Task { @MainActor [weak self, weak observed] in
                    guard let observed else { return }
                    self?.playbackItemFailed(observed, request: request)
                }
            }
            queuedChunk = QueuedChunk(cached: cached, item: item, player: queue)
            queue.actionAtItemEnd = .advance
            queue.insert(item, after: nil)
        }
    }

    /// The player has moved on to the chunk queued behind the one the bookkeeping describes, by itself and with no
    /// app code, or is about to: bring the bookkeeping to that chunk the way `playRenderedAudio` does for a chunk it
    /// starts (#538). `finished` is the item whose end was just heard, if any. True when it did.
    @discardableResult
    private func applyQueuedAdvance(finished: AVPlayerItem?) -> Bool {
        guard applicationIsActive != nil else { return false }
        var finishedURL: URL?
        var replacedObservers: (NSObjectProtocol?, NSKeyValueObservation?)?
        let applied = lock.withLock { () -> Bool in
            guard let queued = queuedChunk, player === queued.player, activeItem !== queued.item else { return false }
            let current = queued.player.currentItem
            if finished != nil, finished === activeItem, current === activeItem {
                // The end of the playing chunk was heard but the queue has not moved on (it is paused at the end,
                // or has not got to the next item yet): the queued chunk is not playing. Take it off and let the
                // seam go through the app, which still has its audio in the cache.
                queued.player.remove(queued.item)
                queued.player.actionAtItemEnd = .pause
                queuedChunk = nil
                return false
            }
            let endHeard = finished != nil && (finished === activeItem || finished === queued.item)
            guard endHeard || current === queued.item else { return false }
            let request = queued.cached.request
            finishedURL = activeAudioURL
            queuedChunk = nil
            renderedCache.removeValue(forKey: request.startOffset)
            activeItem = queued.item
            playerStartedAt = ContinuousClock.now
            activeRequest = request
            activeAudioURL = queued.cached.url
            activeAudioDuration = queued.cached.duration
            currentTargetId = request.targetId
            currentStartOffset = request.startOffset
            currentChunkLength = request.sourceLength
            currentChunkBoundary = request.boundary
            pendingStartTargetId = nil
            startedTargetId = request.targetId
            playbackFailure = nil
            initialRequestedSpokenOffset = nil
            // The chime decider hears every passage in playing order; a queued one is never a stand-in.
            if voiceChangeCueGeneration != request.generation {
                voiceChangeCueGeneration = request.generation
                voiceChangeCueDecider = NarrationVoiceChangeCue()
            }
            _ = voiceChangeCueDecider.leadIn(forStandIn: false)
            // Back to a player that stays on its item at the end, until another chunk is queued behind this one.
            queued.player.actionAtItemEnd = .pause
            // The queued chunk's end observer and failure watch take over from the finished chunk's.
            replacedObservers = (playbackEndObserver, playerItemStatusObservation)
            playbackEndObserver = queuedEndObserver
            queuedEndObserver = nil
            playerItemStatusObservation = queuedStatusObservation
            queuedStatusObservation = nil
            return true
        }
        guard applied else { return false }
        if let finishedChunkObserver = replacedObservers?.0 {
            NotificationCenter.default.removeObserver(finishedChunkObserver)
        }
        replacedObservers?.1?.invalidate()
        if let finishedURL,
           !lock.withLock({ generationResults.values.contains(where: { $0.audioURL == finishedURL }) }) {
            discardAudio(finishedURL)
        }
        recordBackgroundSeam(.queuedAhead)
        // The app's state can only be read on the main thread (the stall monitor calls from another one, where it
        // would always answer "in front" and queue nothing), so the next chunk is queued from there (#538 audit).
        if Thread.isMainThread {
            queueNextChunkIfWanted()
        } else {
            DispatchQueue.main.async { [weak self] in self?.queueNextChunkIfWanted() }
        }
        return true
    }

    /// Counts a seam that came with the app away; the first of each kind also goes into the event log (#538).
    private func recordBackgroundSeam(_ outcome: BackgroundChunkSeam.Outcome) {
        let recorded = lock.withLock { () -> (isNew: Bool, summary: String?) in
            let isNew = backgroundSeams.record(outcome)
            return (isNew, backgroundSeams.summary)
        }
        if let summary = recorded.summary { onBackgroundSeams?(summary) }
        if recorded.isNew {
            onStall?("supertonic.background_seam", [
                "outcome": outcome.rawValue,
                "appState": Self.applicationStateName(),
                "lowPowerMode": String(ProcessInfo.processInfo.isLowPowerModeEnabled)
            ])
        }
    }

    /// Whether the app is in front, for the queue's decision. Off the main thread it answers "in front", which
    /// leaves a seam as it was.
    static func isApplicationActive() -> Bool {
        #if canImport(UIKit) && os(iOS)
        guard Thread.isMainThread else { return true }
        return MainActor.assumeIsolated { UIApplication.shared.applicationState == .active }
        #else
        return true
        #endif
    }

    private func playbackItemFailed(_ item: AVPlayerItem, request: RenderRequest) {
        // A chunk queued behind the playing one that can't play comes off the queue; its seam then goes through the
        // app as it always did (#538).
        applyQueuedAdvance(finished: nil)
        if lock.withLock({ queuedChunk?.item === item }) {
            lock.withLock {
                if let queued = queuedChunk {
                    queued.player.remove(item)
                    queued.player.actionAtItemEnd = .pause
                }
            }
            dropQueuedChunk()
            return
        }
        let failedURL = lock.withLock { () -> URL? in
            guard generation == request.generation,
                  player?.currentItem === item || (player != nil && activeItem === item) else { return nil }
            player?.pause()
            Self.empty(player)
            player = nil
            activeItem = nil
            let url = activeAudioURL
            activeAudioURL = nil
            activeAudioDuration = 0
            return url
        }
        guard let failedURL else { return }
        removePlaybackEndObserver()
        discardAudio(failedURL)
        activateSystemFallback(
            targetId: request.targetId,
            sourceOffset: currentCharOffset()
                ?? sourceOffset(forSpokenOffset: request.startOffset),
            reason: "supertonic_playback_failed"
        )
    }

    private func activateAudioSession(forPlayback: Bool = true) throws {
        if let audioSessionActivator {
            try audioSessionActivator()
            return
        }
        #if os(iOS)
        let options: AVAudioSession.CategoryOptions = lock.withLock {
            PlaybackAudioSessionPolicy.options(mixes: mixesWithOtherAudio, lowersBackground: lowersBackgroundAudio && forPlayback)
        }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: options)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    private func releaseBackgroundAudio() throws {
        #if DEBUG
        lock.withLock { debugBackgroundAudioReleaseCount += 1 }
        #endif
        guard audioSessionActivator == nil,
              lock.withLock({ mixesWithOtherAudio && lowersBackgroundAudio }) else { return }
        #if os(iOS)
        try PlaybackAudioSessionPolicy.releaseDucking()
        #endif
    }

    private func installAudioSessionObservers() {
        #if os(iOS)
        let center = audioSessionNotificationCenter
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            switch type {
            case .began:
                let reason = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                self?.pauseForSystemInterruption(allowsAutomaticResume: true, cause: .interruptionBegan(reasonRawValue: reason))
            case .ended:
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                self?.finishSystemInterruption(
                    shouldResume: AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                )
            @unknown default:
                break
            }
        })
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable else { return }
            self?.pauseForSystemInterruption(allowsAutomaticResume: false, cause: .routeLost)
        })
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Recorded first, so the event log shows the cause before the pause it leads to.
            self.recordSystemPause(.mediaServicesReset, acted: self.lock.withLock { self.transportIntent == .playing })
            self.markMediaServicesReset()
        })
        #endif
    }

    private func pauseForSystemInterruption(allowsAutomaticResume: Bool, cause: SpeechSystemPause) {
        let state = lock.withLock { () -> (didPause: Bool, usesFallback: Bool, activePlayer: AVPlayer?) in
            guard transportIntent == .playing else { return (false, false, nil) }
            transportIntent = .paused
            shouldResumeAfterInterruption = allowsAutomaticResume
            handOverGaps.discardPending()
            return (true, fallbackIsActive, player)
        }
        // A lost route while nothing plays (Bluetooth dropping between listens) isn't worth a log entry.
        if state.didPause || cause != .routeLost { recordSystemPause(cause, acted: state.didPause) }
        guard state.didPause else { return }
        if state.usesFallback {
            try? fallback.pause()
        } else {
            state.activePlayer?.pause()
            try? releaseBackgroundAudio()
        }
        if allowsAutomaticResume { interruptionWaitBegan() }
        interruptionHandler?(.began)
    }

    /// Holds background time from an interruption that asked to resume until iOS reports its end or the listener
    /// takes over (#1434). The audio-session observers run on the main thread.
    /// iOS doesn't report the end of a message announcement, so the hold also resumes once the other audio stops.
    private func interruptionWaitBegan() {
        guard let hold = interruptionHold else { return }
        let begin: @MainActor () -> Void = { [weak self] in
            hold.interruptionBegan(resumeWhenOtherAudioStops: { self?.resumeBecauseOtherAudioStopped() })
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { begin() }
        } else {
            Task { @MainActor in begin() }
        }
    }

    /// The interruption's other audio stopped without iOS reporting an end (#1434): resume as an end with
    /// "should resume" would, unless the listener's own Play, Pause or Stop cleared the request since.
    private func resumeBecauseOtherAudioStopped() {
        let requestsResume = lock.withLock { () -> Bool in
            defer { shouldResumeAfterInterruption = false }
            return shouldResumeAfterInterruption && transportIntent == .paused
        }
        guard requestsResume else { return }
        interruptionHandler?(.endedShouldResume)
    }

    private func interruptionWaitEnded(_ reason: InterruptionBackgroundHold.Outcome) {
        guard let hold = interruptionHold else { return }
        let finish: @MainActor () -> Void = {
            if reason == .ended { hold.interruptionEnded() } else { hold.listenerActed() }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { finish() }
        } else {
            Task { @MainActor in finish() }
        }
    }

    private func finishSystemInterruption(shouldResume: Bool) {
        interruptionWaitEnded(.ended)
        let requestsResume = lock.withLock { () -> Bool in
            defer { shouldResumeAfterInterruption = false }
            return shouldResumeAfterInterruption && shouldResume
        }
        recordSystemPause(.interruptionEnded(shouldResume: shouldResume), acted: requestsResume)
        guard requestsResume else { return }
        interruptionHandler?(.endedShouldResume)
    }

    /// Reports a system pause with the audio session's and player's state, the app's state and
    /// Low Power Mode, so a device export can say why narration stopped in the background (#538).
    private func recordSystemPause(_ cause: SpeechSystemPause, acted: Bool) {
        guard let onSystemPause else { return }
        let (player, usesSystemVoice) = lock.withLock { (self.player, fallbackIsActive) }
        var fields = AudioSessionDiagnostics.fields()
        if usesSystemVoice {
            fields["engine"] = "system_voice"
        } else {
            fields.merge(AudioSessionDiagnostics.fields(for: player)) { first, _ in first }
        }
        fields.merge(cause.fields(
            acted: acted,
            appState: Self.applicationStateName(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )) { _, cause in cause }
        onSystemPause(cause.kind, fields)
    }

    /// The app's state, read on the main thread (the audio-session observers run there).
    private static func applicationStateName() -> String {
        #if canImport(UIKit) && os(iOS)
        guard Thread.isMainThread else { return "unknown" }
        return MainActor.assumeIsolated {
            switch UIApplication.shared.applicationState {
            case .active: "active"
            case .inactive: "inactive"
            case .background: "background"
            @unknown default: "unknown"
            }
        }
        #else
        return "unknown"
        #endif
    }

    /// `announcesPause` is false when the caller is the listener's own pause or play, which the app already knows.
    private func markMediaServicesReset(announcesPause: Bool = true) {
        // Bring the place and the kept chunk up to a queue that has already moved on, before the queued chunk is
        // forgotten below (#538 audit).
        applyQueuedAdvance(finished: nil)
        removePlaybackEndObserver()
        var endedWaitingHandOver = false
        let reset = lock.withLock { () -> (
            didPause: Bool,
            interrupted: (url: URL, duration: TimeInterval, targetId: String, chunkStart: Int, generation: UUID)?
        ) in
            // A reset while the iOS voice has not yet begun: the kept chunk is the one to retain, with the place
            // and length it had before the hand-over took them (#540 audit).
            if let waiting = handOverAwaitingStart {
                endHandOverWait(waiting, as: .returned)
                endedWaitingHandOver = true
            }
            let didPause = transportIntent == .playing
            if let player, activeAudioDuration > 0, currentChunkLength > 0 {
                let fraction = max(0, min(1, playerTime(player) / activeAudioDuration))
                let observedOffset = currentStartOffset + Int(
                    (Double(currentChunkLength) * fraction).rounded(.down)
                )
                // AVAudioSession can reset while a rendered chunk is playing.
                // Preserve the last observable intra-chunk position before the
                // player item is detached; otherwise the next lifecycle sync
                // sees only the chunk start and can overwrite canonical progress.
                initialRequestedSpokenOffset = min(
                    preparedSpeechProjection.text.count,
                    max(currentStartOffset, initialRequestedSpokenOffset ?? currentStartOffset, observedOffset)
                )
            }
            player?.pause()
            Self.empty(player)
            player = nil
            transportIntent = .paused
            // The listener's pause or play, and a system interruption that already asked to resume, keep their say.
            if announcesPause { shouldResumeAfterInterruption = false }
            handOverGaps.discardPending()
            playbackFailure = nil
            pendingStartTargetId = nil
            startedTargetId = nil
            guard let url = activeAudioURL,
                  activeAudioDuration > 0,
                  let targetId = currentTargetId else { return (didPause, nil) }
            let value = (url, activeAudioDuration, targetId, currentStartOffset, generation)
            activeAudioURL = nil
            activeAudioDuration = 0
            return (didPause, value)
        }
        if endedWaitingHandOver {
            try? fallback.stop()
            releaseHandOverBackgroundTimeIfHeld()
            restartRenderQueueBehindKeptChunk()
        }
        guard let interrupted = reset.interrupted else {
            if reset.didPause, announcesPause { interruptionHandler?(.began) }
            return
        }
        // The request the chunk was made with, not one rebuilt from the whole text: a preface chunk rebuilt
        // from the combined text would cover the article's first sentence too, and skip it once played (#540).
        let kept = lock.withLock { () -> RenderRequest? in
            guard var request = activeRequest, request.targetId == interrupted.targetId,
                  request.startOffset == interrupted.chunkStart else { return nil }
            request.generation = interrupted.generation
            return request
        }
        guard let request = kept ?? renderRequest(
                targetId: interrupted.targetId,
                startOffset: interrupted.chunkStart,
                generation: interrupted.generation
              ) else {
            discardAudio(interrupted.url)
            if reset.didPause, announcesPause { interruptionHandler?(.began) }
            return
        }
        let retained = lock.withLock { () -> Bool in
            guard generation == interrupted.generation,
                  currentTargetId == interrupted.targetId,
                  transportIntent == .paused else { return false }
            renderedCache[interrupted.chunkStart] = CachedAudio(
                url: interrupted.url,
                duration: interrupted.duration,
                request: request
            )
            return true
        }
        if !retained { discardAudio(interrupted.url) }
        if reset.didPause, announcesPause { interruptionHandler?(.began) }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
