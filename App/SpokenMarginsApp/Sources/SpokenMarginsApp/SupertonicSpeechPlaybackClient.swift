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

    /// The engine name this renderer's own audio carries (#2700). The player counts a chunk as the chosen voice's
    /// own audio, not a stand-in, only when its result says this engine. Supertonic by default; a downloaded voice's
    /// renderer returns its descriptor's engine.
    var engine: String { get }

    /// This renderer as background preparation must use it: paced whatever the app's state, so it never competes with
    /// live narration for CPU (#377). Supertonic has `BackgroundPreparationRenderer` for that; a downloaded voice's
    /// renderer returns a view of itself that renders with `.always` pacing (#2857).
    func pacedForBackgroundPreparation() -> any SupertonicRendering

    /// True while the renderer is loading its model for the first time (a Neural Engine voice loads and specialises
    /// its Core ML models then, which can take longer than the player's usual wait). The player doesn't give a
    /// waiting listener's passage to the iOS voice for being slow while this is true, up to
    /// `SupertonicSpeechPlaybackClient.maxModelLoadExtensions` more waits (#2856).
    var isLoadingModel: Bool { get }

    /// Loads the model and runs one short render ahead of the first Play, so that first Play doesn't pay the load
    /// (#2856). Best effort: it never throws, and a renderer that has nothing to load does nothing.
    func prepareToRender() async

    /// Where a renderer reports its own events (`voice.load`) for the diagnostics export: voice, timing and error text,
    /// never source text.
    func setEventSink(_ sink: @escaping @Sendable (_ kind: String, _ fields: [String: String]) -> Void)
}

extension SupertonicRendering {
    var engine: String { SupertonicNarrationResult.supertonicEngine }
    func pacedForBackgroundPreparation() -> any SupertonicRendering { self }
    var isLoadingModel: Bool { false }
    func prepareToRender() async {}
    func setEventSink(_ sink: @escaping @Sendable (_ kind: String, _ fields: [String: String]) -> Void) {}
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

extension OnDeviceVoiceGovernor {
    /// The app's one governor: every on-device voice's renderer paces through it, and the app's lifecycle tells it
    /// when the app is in the background, so a voice that takes over there is paced from its first render (#1679).
    static let app = OnDeviceVoiceGovernor(conditions: { SupertonicResourcePolicy.currentConditions() })
}

/// Applies I14 (`SpeechEnginePolicy`) to the device: heat and memory pressure stop new
/// Supertonic inference; Low Power Mode and charging alone don't (#183).
enum SupertonicResourcePolicy {
    static let memoryBackoff = SupertonicMemoryBackoff()

    static func allowsRendering(processInfo: ProcessInfo = .processInfo) -> Bool {
        SpeechEnginePolicy.onDeviceRenderingBlock(currentConditions(processInfo: processInfo)) == nil
    }

    /// What the phone reports now, from any thread. The engine choice ignores the power source (charging alone
    /// never stops or starts a voice, #183), but the render-ahead window decides on it (#2703: a cool phone on
    /// power renders further ahead), so it is read from `power`, never left out.
    static func currentConditions(
        processInfo: ProcessInfo = .processInfo,
        power: any ExternalPowerSource = DevicePowerSource.app
    ) -> SpeechEngineConditions {
        SpeechEngineConditions(
            thermal: thermalLevel(processInfo.thermalState),
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            isOnExternalPower: power.isOnExternalPower,
            isRecoveringFromMemoryWarning: memoryBackoff.isActive()
        )
    }

    /// Whether the device is charging or full on power. Nil when it can't tell (the simulator, off iOS).
    @MainActor
    static func isOnExternalPower() -> Bool? {
        DevicePowerSource.app.startMonitoring()
        return DevicePowerSource.app.isOnExternalPower
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
    /// A stand-in voice let go of an item (#1786): `reason`, `item` and `from` (the voice that held it), so an export
    /// shows every voice change, the ones back to the chosen voice too.
    typealias VoiceRestoredHandler = @Sendable (_ fields: [String: String]) -> Void
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
    /// Per-chunk render speed, voice switches and the session line, for Diagnostics (#2701).
    typealias VoiceTelemetryHandler = @Sendable (_ event: VoiceTelemetryEvent) -> Void
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

    /// What `applyQueuedAdvance` reads from the queue player. Every one of these is an AVFoundation call that can
    /// block when the media server is slow, so they are made outside `lock` (#2242).
    struct QueuedPlayerReading {
        var current: AVPlayerItem?
        /// Only read when the end of the playing chunk was just heard (`includesEndFacts`).
        var queuedChunkIsOnThePlayer = false
        var playerAdvancesAtItemEnd = false
        var playerIsPlaying = false
    }

    typealias QueuedPlayerReader = @Sendable (_ player: AVQueuePlayer, _ queuedItem: AVPlayerItem, _ includesEndFacts: Bool) -> QueuedPlayerReading

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
    /// Reads a player's clock in seconds. Nil reads `currentTime()`; a test supplies one that blocks, as
    /// AVFoundation can when the media server is slow (#2119).
    private let playerClock: (@Sendable (AVPlayer) -> TimeInterval)?
    /// Reads the queue player's current item and end-of-item facts. Nil reads the player; a test supplies one that
    /// blocks, as AVFoundation can when the media server is slow (#2242).
    private let queuedPlayerReader: QueuedPlayerReader?
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
    /// How many more `renderWaitLimit` waits a render gets while its renderer is still loading its model (#2856):
    /// 15 s plus 8 × 15 s, two minutes in all, for a Core ML voice's first Neural Engine specialisation.
    static let maxModelLoadExtensions = 8
    /// How long a background seam handed to the bundled voice waits in silence for its render (#1786 audit).
    private let backgroundGapWaitLimit: Duration
    private var playbackRate: Float
    private var mixesWithOtherAudio = false
    private var lowersBackgroundAudio = false
    /// What this client last activated the audio session with, kept until the run ends, the system takes the
    /// session or another component changes it. A chunk seam finds it set and skips the IPC (#2101).
    private var activatedSessionKey: ActivatedSessionKey?
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
    /// The render chain's next chunk, held back while enough audio waits ahead (#1681). Queued again once playback
    /// has used half the window, the limit lifts, or playback waits for a chunk.
    private var restingRender: RenderRequest?
    /// The last progress reported, so a resting chain that starts again can report it without the rest (#1681).
    private var reportedProgress = RenderedSpeechGenerationProgress(completedChunks: 0, totalChunks: 0)
    /// Each rendered chunk's audio length, by start, so the audio ahead counts chunks already played once and played
    /// again after a skip back (#1681). Read only where `generationResults` holds the chunk.
    private var renderedDurations: [Int: TimeInterval] = [:]
    /// How often a resting chain started again before playback had to wait for a chunk (#1681).
    private var renderAheadRestarts = 0
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
    /// Which stand-in voice holds which item (#1786). Kept across plays, stops and generations of the item, so a
    /// resume, an interruption's end, the phone cooling or the app coming to the front never changes the voice; only
    /// `NarrationVoiceHold`'s releases do. Guarded by `lock`.
    private var voiceHold = NarrationVoiceHold()
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
    private let onVoiceRestored: VoiceRestoredHandler?
    /// Told when the bundled Kitten voice starts playing in place of Supertonic (#849 audit, I14), with the resource
    /// that refused Supertonic when Kitten took over, so the listener sees why and diagnostics log it. Never after a
    /// play released the voice. `onRestore` clears it.
    private let onBundledVoice: BundledVoiceHandler?
    private let onStall: StallHandler?
    private let onSystemPause: SystemPauseHandler?
    private let onRenderPace: RenderPaceHandler?
    private let onVoiceTelemetry: VoiceTelemetryHandler?
    /// Whether the app is in front. With it the player is a queue, and while the app is away the next rendered
    /// chunk goes onto it before the playing one ends, so the seam needs no app code (#538). nil leaves every seam as
    /// it was: one player per chunk. Read on the main thread; anywhere else the app counts as in front.
    private let applicationIsActive: (@Sendable () -> Bool)?
    /// True only when the app is in the background. Control Center, a call banner and the app switcher make the app
    /// inactive while the listener is looking at it, and the voice must not change then (#849, #1673). Without
    /// one, "not active" counts as away.
    private let applicationIsInBackground: (@Sendable () -> Bool)?
    private let onBackgroundSeams: BackgroundSeamHandler?
    /// The listening live narration may render ahead now; nil for no limit (#1681).
    private let renderAheadWindow: @Sendable () -> TimeInterval?
    /// The window the app's clients use: the app's background state and what the phone reports now, power included,
    /// through `RenderAheadPolicy` (#1681, #2703).
    static let defaultRenderAheadWindow: @Sendable () -> TimeInterval? = {
        RenderAheadPolicy.window(appBackgrounded: OnDeviceVoiceGovernor.app.isAppBackgrounded,
                                 conditions: OnDeviceVoiceGovernor.app.conditions())
    }
    /// The governor whose shared CPU budget this client's live narration answers to; it reads `liveNarrationBuffer()`
    /// at every budget check once this client plays (#2695).
    private let governor: OnDeviceVoiceGovernor
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
    /// Runs once that handling has finished on the main actor, so a test can check its effect without a fixed wait (#2747).
    var debugStallWasHandled: (@Sendable () -> Void)?
    /// How often the client asked to stop lowering other apps' audio.
    private(set) var debugBackgroundAudioReleaseCount = 0
    var debugHasStallMonitor: Bool { lock.withLock { stallMonitor != nil } }
    /// Where the chunk queued behind the playing one starts, nil when none is queued (#538).
    var debugQueuedChunkStart: Int? { lock.withLock { queuedChunk?.cached.request.startOffset } }
    /// The count of seams that came with the app away, as the export shows it (#538).
    var debugBackgroundSeamSummary: String? { lock.withLock { backgroundSeams.summary } }
    /// How often a resting render chain started again with playback not waiting for a chunk (#1681).
    var debugRenderAheadRestarts: Int { lock.withLock { renderAheadRestarts } }
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
    /// Whether this client resumes by itself when an interruption ends. The decision belongs to
    /// `SystemInterruptionResume` (#3032); this client reports events to it and obeys the answer. Guarded by `lock`.
    private var interruptionResume = SystemInterruptionResume()
    private var activeRenderControl: RenderTaskControl?
    /// The last measured chunk's render speed over the listening speed, for `RenderAheadPolicy.resumeMark` (#2703). It
    /// counts only under the voice, app state and generation it was measured in, so a foreground or other-voice value
    /// can't lower the resume mark after backgrounding, a hand-over, a seek or a new item.
    private var renderHeadroom = RenderHeadroomMemory()

    /// Whether speculative Library work may share the serial renderer: two committed chunks wait past the audible one,
    /// and no stand-in holds the item, since Kitten renders beside Supertonic, not in turn (#2695).
    var canYieldRendererToLibrary: Bool {
        lock.withLock {
            var offset = currentStartOffset + currentChunkLength, ahead = 0
            while ahead < OnDeviceRenderAdmission.chunksAheadForLibrary, offset < preparedSpeechProjection.text.count,
                  let chunk = renderedCache[offset] { ahead += 1; offset += chunk.request.sourceLength }
            return OnDeviceRenderAdmission.libraryMayShareRenderer(.init(
                isPlaying: transportIntent == .playing,
                standInHolds: fallbackIsActive || bundledVoiceGeneration == generation || startedTargetId.map(voiceHold.holds) == true,
                isWaiting: pendingAutoplayOffset != nil || startedTargetId == nil, isFullyRendered: generationState == .ready,
                chunksAhead: offset >= preparedSpeechProjection.text.count ? Int.max : ahead))
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
        playerClock: (@Sendable (AVPlayer) -> TimeInterval)? = nil,
        queuedPlayerReader: QueuedPlayerReader? = nil,
        observesPlayerLifecycle: Bool = true,
        voiceChangeCue: (@Sendable () -> Void)? = nil,
        onDeviceRenderingAllowed: @escaping @Sendable () -> Bool = { OnDeviceVoiceGovernor.app.supertonicRenderingBlock() == nil },
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
        onVoiceRestored: VoiceRestoredHandler? = nil,
        onBundledVoice: BundledVoiceHandler? = nil,
        onStall: StallHandler? = nil,
        onSystemPause: SystemPauseHandler? = nil,
        stallThreshold: Duration = .seconds(5),
        stallSampleInterval: Duration = .seconds(1),
        stallRecoveryCooldown: Duration = .seconds(30),
        onResumeDecision: ResumeDecisionHandler? = nil,
        renderWaitLimit: Duration = .seconds(15),
        backgroundGapWaitLimit: Duration = .seconds(5),
        onRenderPace: RenderPaceHandler? = nil,
        onVoiceTelemetry: VoiceTelemetryHandler? = nil,
        handOverHold: HandOverBackgroundHold? = nil,
        interruptionHold: InterruptionBackgroundHold? = nil,
        applicationIsActive: (@Sendable () -> Bool)? = nil,
        applicationIsInBackground: (@Sendable () -> Bool)? = nil,
        onBackgroundSeams: BackgroundSeamHandler? = nil,
        renderAheadWindow: @escaping @Sendable () -> TimeInterval? = SupertonicSpeechPlaybackClient.defaultRenderAheadWindow,
        governor: OnDeviceVoiceGovernor = .app
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
        self.playerClock = playerClock
        self.queuedPlayerReader = queuedPlayerReader
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
        self.onVoiceRestored = onVoiceRestored
        self.onBundledVoice = onBundledVoice
        self.onStall = onStall
        self.onSystemPause = onSystemPause
        self.stallThreshold = stallThreshold
        self.stallSampleInterval = stallSampleInterval
        self.stallRecoveryCooldown = stallRecoveryCooldown
        self.articleText = articleText
        self.onResumeDecision = onResumeDecision
        self.renderWaitLimit = renderWaitLimit
        self.backgroundGapWaitLimit = backgroundGapWaitLimit
        self.onRenderPace = onRenderPace
        self.onVoiceTelemetry = onVoiceTelemetry
        self.handOverHold = handOverHold
        self.interruptionHold = interruptionHold
        self.applicationIsActive = applicationIsActive
        self.applicationIsInBackground = applicationIsInBackground
        self.onBackgroundSeams = onBackgroundSeams
        self.renderAheadWindow = renderAheadWindow
        self.governor = governor
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
        governor.readLiveNarrationBuffer { [weak self] in self?.liveNarrationBuffer() }
        applyQueuedAdvance(finished: nil)
        settleHandOverBeforePlay()
        interruptionWaitEnded(.listenerActed)
        // A play is the listener's own act, and other audio (a spoken Margin) may have released the session since the
        // last one; the seams that follow reuse this activation.
        forgetActivatedSession()
        try activateAudioSession(forPlayback: false)
        // Only another item, or this one having played to its end, lets a stand-in go at a play (#1786).
        let systemVoiceFinished = lock.withLock { voiceHold.voice(for: targetId) == .system }
            && fallback.isPlaybackComplete(targetId: targetId)
        updateVoiceHold { hold in
            systemVoiceFinished ? hold.itemEnded(targetId) : hold.play(item: targetId)
        }
        restoreOnDeviceRenderingIfConditionCleared(targetId: targetId)
        let usesStoppedGeneration = lock.withLock {
            interruptionResume.cancelAutomaticResume()
            // The iOS voice holding the item keeps it after a stop cleared the reasons below, too.
            return generationDisabledReasons[targetId] != nil
                || (fallbackIsActive && currentTargetId == targetId)
                || voiceHold.voice(for: targetId) == .system
        }
        if usesStoppedGeneration {
            try playFallbackVoice(targetId: targetId, from: charOffset)
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

    /// I14 for the bundled voice: once Supertonic is allowed again, a play of another item, or of this one after it
    /// ended, releases the generation from Kitten (#1786: a resume or seek inside the item no longer does) and lets go of the chunks after the one holding the playhead that are rendered and
    /// waiting, from the first Kitten one on, so they render again with Supertonic. The whole waiting run goes, not
    /// only its Kitten chunks: the render chain stops at the first chunk still waiting, so a Kitten chunk past it
    /// would never be rendered again (#849 audit). The chunk holding the playhead is finished first, so the voice
    /// never changes mid-sentence (#849).
    private func replaceBundledVoiceChunks(after spokenOffset: Int, targetId: String) {
        guard pressureRenderer != nil, onDeviceRenderingAllowed() else { return }
        let work = lock.withLock { () -> (urls: [URL], restart: RenderRequest?, told: Bool) in
            // The bundled voice holding this item keeps it through the play, cooled phone or not (#1786).
            if voiceHold.holds(targetId) { return ([], nil, false) }
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

    /// Kitten renders the rest of `request`'s generation from here on, and holds its item until `voiceHold` lets go
    /// (#849 audit, #1786).
    private func holdBundledVoice(for request: RenderRequest) {
        let block = OnDeviceVoiceGovernor.app.supertonicRenderingBlock()
        lock.withLock {
            guard self.generation == request.generation else { return }
            if bundledVoiceGeneration != request.generation {
                bundledVoiceBlock = block
                onVoiceTelemetry?(.switched(to: KittenNarrationRenderer.engine, reason: block?.rawValue ?? "bundled_voice_held"))
            }
            bundledVoiceGeneration = request.generation
            savedRunGeneration = nil
            voiceHold.standInTookOver(.bundled, item: request.targetId)
        }
    }

    /// Applies one change to `voiceHold` and, when it let a stand-in go, says so in diagnostics (`voice.restored`).
    @discardableResult
    private func updateVoiceHold(
        _ change: (inout NarrationVoiceHold) -> NarrationVoiceHold.Release?
    ) -> NarrationVoiceHold.Release? {
        let released = lock.withLock { () -> [String: String]? in
            let item = voiceHold.item
            let from = voiceHold.holder
            guard let reason = change(&voiceHold), let item else { return nil }
            return ["reason": reason.rawValue, "item": item, "from": from.rawValue]
        }
        guard let released else { return nil }
        onVoiceRestored?(released)
        onVoiceTelemetry?(.restored(reason: released["reason"] ?? "released"))
        return released["reason"].flatMap(NarrationVoiceHold.Release.init(rawValue:))
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
        let started = lock.withLock {
            guard generation == request.generation else { return false }
            savedRunGeneration = request.generation
            if bundledVoiceGeneration == request.generation { bundledVoiceGeneration = nil }
            return true
        }
        // The one release inside an item: the bundled voice takes the item again at the run's end only if the phone
        // still refuses Supertonic then (#1680, #1786).
        if started { updateVoiceHold { $0.savedRunStarted(item: request.targetId) } }
        return started
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
                                             renderDuration: 0, sessionLoadCount: 0, engine: renderer.engine)
        }
        return diskCache?.cachedAudio(text: planned.text, voice: voice, language: "en", speed: 1.0, synthesisSteps: 8)
    }

    /// I14: the chosen voice comes back once the condition that forced the fallback clears.
    /// It switches at a play (resume, seek, next item), never mid-sentence.
    private func restoreOnDeviceRenderingIfConditionCleared(targetId: String) {
        // The iOS voice holding the item keeps it to the item's end (#1786); `play` has let go of another item's hold.
        // The bundled voice holding it doesn't block the return from a memory warning or a stalled player: the
        // iOS voice stood in for a fault there, and the new generation goes back to the bundled voice (`nextRequest`).
        let restoresVoice = onDeviceRenderingAllowed() && lock.withLock {
            resourceFallbackTargetIds.contains(targetId) && voiceHold.voice(for: targetId) != .system
        }
        if restoresVoice { try? pauseFallbackVoice() }
        let restartsHeldQueue = lock.withLock { () -> Bool in
            if restoresVoice {
                resourceFallbackTargetIds.remove(targetId)
                generationDisabledReasons.removeValue(forKey: targetId)
                fallbackIsActive = false
            }
            defer { if restoresVoice { heldRenderQueueGeneration = nil } }
            return heldRenderQueueGeneration == generation
        }
        if restoresVoice { onRestore?(targetId); onVoiceTelemetry?(.restored(reason: "condition_cleared")) }
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
    /// The render headroom the resume mark would read for the current generation in the app's current state (#2703).
    func debugRenderHeadroom(isStandIn: Bool) -> Double? {
        let backgrounded = governor.isAppBackgrounded
        return lock.withLock {
            renderHeadroom.headroom(in: .init(isStandIn: isStandIn, isInBackground: backgrounded, generation: generation))
        }
    }

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
        forgetActivatedSession()
        let snapshot = lock.withLock { () -> (Bool, AVPlayer?) in
            transportIntent = .paused
            interruptionResume.cancelAutomaticResume()
            handOverGaps.discardPending()
            return (fallbackIsActive, player)
        }
        if snapshot.0 {
            try pauseFallbackVoice()
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
        onVoiceTelemetry?(.sessionEnded)
        interruptionWaitEnded(.listenerActed)
        forgetActivatedSession()
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
            interruptionResume.cancelAutomaticResume()
            handOverAwaitingStart = nil
            generationDisabledReasons.removeAll()
            resourceFallbackTargetIds.removeAll()
            generationPlan.removeAll()
            generationRenderOrder.removeAll()
            generationResults.removeAll()
            renderedDurations.removeAll()
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
        try stopFallbackVoice()
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
            renderedDurations.removeAll()
            standInOffsets.removeAll()
            bundledVoiceOffsets.removeAll()
            failedRenderReasons.removeAll()
            initialPlaybackOffset = nil
            initialRequestedSpokenOffset = nil
            preparedAudioAssemblyStarted = false
            interruptionResume.cancelAutomaticResume()
            return (Array(urls), renderControl)
        }
        stopped.renderControl?.cancel()
        for url in stopped.urls { discardAudio(url) }

        try playFallbackVoice(targetId: targetId, from: offset)
        onVoiceTelemetry?(.switched(to: "ios", reason: stopReason))
        if state.1 == .paused {
            try pauseFallbackVoice()
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
        try stopFallbackVoice()
        onVoiceTelemetry?(.restored(reason: "listener_retry"))
        updateVoiceHold { $0.listenerChoseVoice() }
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
        // Playback used some of the audio ahead: a resting render chain may start again (#1681).
        defer { resumeRenderAheadIfWanted() }
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
            if let finished = snapshot.1 { updateVoiceHold { $0.itemEnded(finished) } }
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
        var backgroundGap = false
        if let applicationIsActive, !applicationIsActive() {
            let isStandIn = lock.withLock { standInOffsets.contains(snapshot.0) }
            let outcome = BackgroundChunkSeam.missedOutcome(
                nextChunkIsRendered: snapshot.3 != nil, nextChunkIsStandIn: isStandIn
            )
            recordBackgroundSeam(outcome)
            backgroundGap = BackgroundChunkSeam.handsOverToSystemVoice(outcome)
                && (applicationIsInBackground?() ?? true)
        }
        if let cached = snapshot.3 {
            playRenderedAudio(cached.url, duration: cached.duration, request: cached.request, delay: snapshot.4)
        } else if let reason = lock.withLock({ failedRenderReasons[snapshot.0] }) {
            activateSystemFallback(
                targetId: targetId,
                sourceOffset: sourceOffset(forSpokenOffset: snapshot.0),
                reason: reason
            )
        } else if backgroundGap, pressureRenderer != nil, lock.withLock({
            voiceHold.backgroundGapStandIn(item: targetId, bundledVoiceAvailable: true) == .bundled
        }) {
            // The bundled voice stands in, not the iOS voice, and keeps the item (#1786). The seam keeps its
            // background time until that chunk plays; a render that doesn't land within the seam's short deadline
            // hands the seam to the iOS voice.
            handBackgroundGapToBundledVoice(request)
        } else if backgroundGap, startSystemVoiceAheadOfHandOver(
            targetId: targetId, sourceOffset: sourceOffset(forSpokenOffset: snapshot.0)
        ) {
            // Nothing is playing and the next chunk isn't rendered: a suspended app could not start it when it
            // lands. The iOS voice is reading on from here; the hand-over now takes the article over, and the chosen
            // voice comes back at the next play (#1673). With the voice speaking, the stall monitor ends the
            // background-time hold once it is moving.
            activateSystemFallback(
                targetId: targetId,
                sourceOffset: sourceOffset(forSpokenOffset: snapshot.0),
                reason: Self.backgroundGapReason,
                voiceAlreadyStarted: true
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
            if currentTargetId != targetId { renderPace = RenderPaceLog(); onVoiceTelemetry?(.sessionEnded) }
            // The bundled voice holding the item reads the new generation too, without announcing itself again (#1786).
            if voiceHold.voice(for: targetId) == .bundled {
                if bundledVoiceNoticeGeneration != nil { bundledVoiceNoticeGeneration = nextGeneration }
                bundledVoiceGeneration = nextGeneration
            }
            currentTargetId = targetId
            activeSourceText = preparedSourceText
            currentStartOffset = max(0, min(spokenOffset, source.count))
            currentChunkLength = 0
            transportIntent = .playing
            generationPlan.removeAll()
            generationRenderOrder.removeAll()
            generationResults.removeAll()
            renderedDurations.removeAll()
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
        if pressureRenderer != nil,
           !onDeviceRenderingAllowed() || lock.withLock({ bundledVoiceGeneration == snapshot.generation }),
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
                engine: bundledVoice ? KittenNarrationRenderer.engine : renderer.engine
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
        let loadingRenderer = renderer
        let task = Task { [weak self, renderer, voice, pressureRenderer] in
            // Each renderer deletes only the files it wrote and ignores the rest.
            let discard: @Sendable (URL) async -> Void = { url in
                await renderer.discardGeneratedAudio(at: url)
                await pressureRenderer?.discardGeneratedAudio(at: url)
            }
            let timeout = Task { @MainActor [weak self] in
                var loadExtensions = 0
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
                    // A voice's first render loads its model; that load isn't a slow render (#2856).
                    if loadingRenderer.isLoadingModel, loadExtensions < Self.maxModelLoadExtensions {
                        loadExtensions += 1
                        continue
                    }
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
                var renderStartConditions: SpeechEngineConditions?
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
                        sessionLoadCount: 0,
                        engine: renderer.engine
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
                    self?.holdBundledVoice(for: request)
                    chunk = saved.request
                    result = saved.result
                    self?.reportSavedBundledVoiceStart(request: saved.request)
                } else {
                    // Supertonic is not allowed now, or the bundled voice holds this generation: the bundled Kitten
                    // voice renders the chunk when there is one, otherwise the iOS voice takes the passage (#849).
                    let allowedNow = self?.onDeviceRenderingAllowed() != false
                    let usesPressureRenderer = OnDeviceRenderAdmission.liveRenderer(
                        chosenAllowed: allowedNow, standInHolds: holdsBundledVoice, standInAvailable: pressureRenderer != nil) == .standIn
                    guard allowedNow || usesPressureRenderer else {
                        await MainActor.run {
                            self?.renderFailed(request: request, shouldPlayWhenReady: shouldPlayWhenReady,
                                               reason: "supertonic_resource_pressure")
                        }
                        return
                    }
                    let renderStartedAt = ContinuousClock.now
                    renderStartConditions = SupertonicResourcePolicy.currentConditions()
                    let rendered: SupertonicNarrationResult
                    if usesPressureRenderer, let pressureRenderer {
                        self?.holdBundledVoice(for: request)
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
                    // Only the chosen voice's own audio is cached under its key. An iOS-voice stand-in
                    // isn't, so the next play renders the voice again and re-checks it (#311). The cache is
                    // Supertonic's (keyed by its voice), so the player gets one only for James and Lily.
                    if self?.isChosenVoiceAudio(rendered.engine) == true,
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
                    self?.holdBundledVoice(for: request)
                    let renderStartedAt = ContinuousClock.now
                    renderStartConditions = SupertonicResourcePolicy.currentConditions()
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
                    self?.recordRenderPace(request: chunk, audioSeconds: result.duration, wall: renderWall, engine: result.engine, startConditions: renderStartConditions)
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
            if isChosenVoiceAudio(result.engine) {
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
            renderedDurations[request.startOffset] = result.duration

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
        let next = action.next.flatMap { rendersAhead($0) ? $0 : nil }
        reportGenerationProgress(
            completedChunks: action.completedChunks,
            totalChunks: action.totalChunks,
            restingAhead: action.next != nil && next == nil
        )
        if let next {
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
    /// Why a seam with the app away and the next chunk not rendered hands over to the iOS voice (`SpeechFallbackReason`:
    /// `backgroundGap`, #1673).
    private static let backgroundGapReason = "supertonic_background_gap"

    /// A seam with the app in the background found the next chunk unrendered (#1786). When the bundled voice already
    /// reads this generation its render of that chunk is under way, and the seam waits for it. Otherwise Supertonic's
    /// chain is let go and a new generation from that chunk on is the bundled voice's, so the old chain's late results
    /// can't land in it. The chunk plays as soon as it is rendered, or from the bundled voice's saved audio at once.
    /// A seam never stays silent longer than `backgroundGapWaitLimit`: the iOS voice is the last resort
    /// (`handBackgroundGapToSystemVoiceIfStillSilent`).
    private func handBackgroundGapToBundledVoice(_ request: RenderRequest) {
        let work = lock.withLock { () -> (next: RenderRequest?, cancel: RenderTaskControl?, waits: UUID?) in
            guard generation == request.generation else { return (nil, nil, nil) }
            pendingAutoplayOffset = request.startOffset
            voiceHold.standInTookOver(.bundled, item: request.targetId)
            if bundledVoiceGeneration == generation {
                return (inFlightOffsets.contains(request.startOffset) ? nil : request, nil, generation)
            }
            let previous = generation
            generation = UUID()
            handOverGaps.pendingMoved(from: previous, to: generation)
            let control = activeRenderControl
            activeRenderControl = nil
            inFlightOffsets.removeAll()
            generationPlan = Self.rebound(generationPlan, to: generation)
            preparationPlan = Self.rebound(preparationPlan, to: generation)
            generationRenderOrder = Self.rebound(
                generationRenderOrder.filter { $0.startOffset >= request.startOffset }, to: generation)
            let rebind = generation
            renderedCache = renderedCache.mapValues { cached in
                var cached = cached
                cached.request.generation = rebind
                return cached
            }
            // A chain resting ahead (#1681) or a split first chunk (#849) restarts in the new generation, or never lands.
            restingRender = restingRender.flatMap { $0.startOffset >= request.startOffset ? Self.rebound([$0], to: rebind).first : nil }
            fastStartOriginals = fastStartOriginals.mapValues { Self.rebound([$0], to: rebind)[0] }
            bundledVoiceGeneration = generation
            bundledVoiceBlock = .backgroundGap
            savedRunGeneration = nil
            var next = request
            next.generation = generation
            return (next, control, generation)
        }
        work.cancel?.cancel()
        if let next = work.next { enqueueRender(next, shouldPlayWhenReady: false) }
        guard let waits = work.waits else { return }
        let limit = backgroundGapWaitLimit
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: limit)
            self?.handBackgroundGapToSystemVoiceIfStillSilent(request, generation: waits)
        }
    }

    /// The bundled voice's render for a background seam hasn't landed within `backgroundGapWaitLimit`, so nothing has
    /// played since the seam (#1673 / #1705: a background seam never goes silent). The iOS voice reads on from the
    /// seam and keeps the item, as it does without the bundled voice. Kitten's render runs on the main actor's
    /// callbacks too, so it can't land between this check and the hand-over. A play, seek or stop since the seam, or
    /// the app back in front (where the chunk starts when it lands), leaves the seam alone.
    @MainActor
    private func handBackgroundGapToSystemVoiceIfStillSilent(_ request: RenderRequest, generation waits: UUID) {
        let silent = lock.withLock {
            generation == waits && pendingAutoplayOffset == request.startOffset && transportIntent == .playing
        }
        guard silent, applicationIsInBackground?() ?? true else { return }
        let sourceOffset = sourceOffset(forSpokenOffset: request.startOffset)
        guard startSystemVoiceAheadOfHandOver(targetId: request.targetId, sourceOffset: sourceOffset) else { return }
        activateSystemFallback(
            targetId: request.targetId,
            sourceOffset: sourceOffset,
            reason: Self.backgroundGapReason,
            voiceAlreadyStarted: true
        )
    }

    /// Starts the iOS voice at the next chunk's place before anything of the chosen voice is touched, for a seam with
    /// the app in the background and the next chunk not rendered (#1673). If the voice can't start, nothing has
    /// changed: the seam waits for its render as it always did, with its generation, queue and voice hold intact.
    private func startSystemVoiceAheadOfHandOver(targetId: String, sourceOffset: Int) -> Bool {
        do {
            _ = try fallback.prepareSpeechText(lock.withLock { preparedSourceText })
            try playFallbackVoice(targetId: targetId, from: sourceOffset)
            if case .failed = fallback.playbackStartStatus(targetId: targetId) { throw HandOverStartFailed() }
            return true
        } catch {
            try? stopFallbackVoice()
            return false
        }
    }

    /// `voiceAlreadyStarted`: the iOS voice is speaking from `sourceOffset` already (`startSystemVoiceAheadOfHandOver`);
    /// this takes the article over without starting it again.
    private func activateSystemFallback(targetId: String, sourceOffset: Int, reason: String, voiceAlreadyStarted: Bool = false) {
        // The iOS voice sets up and releases the session itself.
        forgetActivatedSession()
        // A stalled player's chunk is kept until the iOS voice is really speaking. If it can't start, the
        // pause for a tap replays that chunk (#302) instead of rendering it again.
        let keepsChunk = reason == Self.stalledPlayerReason
        let source = lock.withLock { preparedSourceText }
        // The stop names why the iOS voice took over, so the player's line needs nothing else (#314).
        let stopReason = SpeechFallbackReason(
            supertonicCode: reason,
            resourceBlock: OnDeviceVoiceGovernor.app.supertonicRenderingBlock()
        ).rawValue
        var cancelledRenderQueue = false
        do {
            if !voiceAlreadyStarted { _ = try fallback.prepareSpeechText(source) }
            removePlaybackEndObserver()
            let stopped = lock.withLock { () -> (urls: [URL], renderControl: RenderTaskControl?, kept: URL?) in
                generation = UUID()
                let renderControl = activeRenderControl
                activeRenderControl = nil
                generationDisabledReasons[targetId] = stopReason
                if reason == "supertonic_resource_pressure" || reason == Self.stalledPlayerReason
                    || reason == Self.backgroundGapReason {
                    resourceFallbackTargetIds.insert(targetId)
                    // Taking over for the phone's condition, the iOS voice keeps the item (#1786). A stalled player
                    // and a memory warning are faults, not the phone, so they still get the chosen voice back at the
                    // next play (#540, I14), as their player line says.
                    if reason != Self.stalledPlayerReason, stopReason != SpeechFallbackReason.memoryWarning.rawValue {
                        voiceHold.standInTookOver(.system, item: targetId)
                    }
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
                renderedDurations.removeAll()
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
            if !voiceAlreadyStarted { try playFallbackVoice(targetId: targetId, from: sourceOffset) }
            onVoiceTelemetry?(.switched(to: "ios", reason: stopReason))
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
            if keepsChunk { try? stopFallbackVoice() }
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
            if lock.withLock({ fallbackIsActive }) { try stopFallbackVoice() }
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
                    // The clock is read outside `lock`: if AVFoundation blocks, only this sample waits, not
                    // every caller of the client (#2119). A player swapped since then reads as a fresh one at zero.
                    let sampledPlayer = self.lock.withLock { self.fallbackIsActive ? nil : self.player }
                    let sampledSeconds = self.playerTime(sampledPlayer)
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
                        let time = self.player === sampledPlayer ? sampledSeconds : 0
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
                        #if DEBUG
                        self.debugStallWasHandled?()
                        #endif
                    } else if stallOngoing, sample.intends {
                        #if DEBUG
                        self.debugStallWillBeHandled?()
                        #endif
                        await MainActor.run { self.pauseIfReseatDidNotHelp(sampled: sample.watched) }
                        #if DEBUG
                        self.debugStallWasHandled?()
                        #endif
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
                interruptionResume.cancelAutomaticResume()
                return true
            }
            guard paused else { return }
            try? pauseFallbackVoice()
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
        try? reactivateAudioSession()
        try? pauseFallbackVoice()
        try? playFallbackVoice(targetId: targetId, from: offset)
    }

    /// Re-activates the session and plays the same chunk from the same point in a new player.
    private func reseatStalledPlayer() {
        applyQueuedAdvance(finished: nil)
        // The clock is read outside `lock` (#2119); a player replaced since then needs no re-seat.
        let sampledPlayer = lock.withLock { player }
        let time = playerTime(sampledPlayer)
        let snapshot = lock.withLock { () -> (URL, TimeInterval, RenderRequest, TimeInterval)? in
            guard transportIntent == .playing, player === sampledPlayer,
                  let request = activeRequest, let url = activeAudioURL else { return nil }
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
        try? reactivateAudioSession()
        playRenderedAudio(url, duration: duration, request: request)
    }

    /// The system's reason when a player's start is turned down (`AVPlayerRateDidChangeReasonSetRateFailed`).
    private static let refusedStartReason = "SetRateFailed"
    /// How long a refused start gets to clear by itself before the player is recovered (#1763).
    private static let refusedStartGrace: Duration = .seconds(1)

    /// A new player the system would not start with the app in the background: it sits at time 0 with rate 0, and
    /// the watchdog needed `stallThreshold` of silence to notice, then as long again before handing over, so the
    /// listener with the phone locked heard nothing for 10 s or more (#1763). A refusal that is still standing a
    /// moment later is a stall now: the first one re-seats the player, and one that comes within the cooldown, from
    /// the re-seated player, goes the way a re-seat that did not help always has, to the iOS voice. Not in front
    /// of the listener, who can tap, and not once the system's interruption has paused us. The app's state is read
    /// after the grace, so a refusal that came as the phone was locking (still inactive) is caught.
    @MainActor
    private func recoverFromRefusedStart(of refused: AVPlayer) async {
        try? await Task.sleep(for: Self.refusedStartGrace)
        guard applicationIsInBackground?() == true, refused.rate == 0,
              lock.withLock({ !fallbackIsActive && handOverAwaitingStart == nil }),
              isStillPlaying(WatchedPlayback(player: ObjectIdentifier(refused))) else { return }
        var fields = AudioSessionDiagnostics.fields().merging(AudioSessionDiagnostics.fields(for: refused)) { first, _ in first }
            .merging(stallContextFields(player: refused)) { first, _ in first }
        fields["cause"] = "set_rate_failed"
        guard claimStallRecovery() else { return pauseStalledPlayback(fields) }
        fields["recovery"] = "reseat_player"
        onStall?("supertonic.stall", fields)
        reseatStalledPlayer()
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
            try? stopFallbackVoice()
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
        try? stopFallbackVoice()
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
             standIn: standInOffsets.contains(currentStartOffset), bundled: bundledVoiceOffsets.contains(currentStartOffset),
             audioSeconds: activeAudioDuration)
        }
        let lastChange = rateChangeLock.withLock { lastRateChange }
        let playerAge: String = snapshot.created.map { ms(now - $0) } ?? "none"
        let startAgo: String = snapshot.started.map { ms(now - $0) } ?? "never"
        let chunkAudio = String(Int((snapshot.audioSeconds * 1_000).rounded()))
        var fields: [String: String] = [
            "appState": Self.applicationStateName(),
            "conditions": SupertonicResourcePolicy.currentConditions().logDescription,
            "chunkEngine": snapshot.bundled ? KittenNarrationRenderer.engine
                : snapshot.standIn ? SupertonicNarrationResult.systemVoiceEngine : renderer.engine,
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

    /// Whether a result with `engine` is the chosen voice's own audio rather than a stand-in (Kitten or the iOS
    /// voice). The one place the player decides it, for caching, stand-in marking and render headroom alike: three
    /// spellings of it drifted before (#2700, #2762 audit), one still comparing with Supertonic's name.
    private func isChosenVoiceAudio(_ engine: String) -> Bool {
        engine == renderer.engine
    }

    /// Keeps how fast a chunk rendered against how fast it plays, and reports the log's summary (#540).
    private func recordRenderPace(
        request: RenderRequest, audioSeconds: TimeInterval, wall: Duration, engine: String,
        startConditions: SpeechEngineConditions?
    ) {
        let conditions = SupertonicResourcePolicy.currentConditions()
        let wallSeconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
        let rate = lock.withLock { Double(playbackRate) }
        let chunk = VoiceRenderChunk(
            engine: engine,
            voiceId: engine == SupertonicNarrationResult.supertonicEngine ? "supertonic:\(voice.rawValue)" : engine,
            audioSeconds: audioSeconds,
            computeSeconds: wallSeconds,
            listeningSpeed: rate,
            thermalAtStart: (startConditions ?? conditions).thermal,
            thermalAtEnd: conditions.thermal,
            isInBackground: applicationIsInBackground?() ?? false,
            isLowPowerModeEnabled: conditions.isLowPowerModeEnabled
        )
        onVoiceTelemetry?(.chunk(chunk))
        if chunk.isMeasurable { // the resume mark's input (#2703), kept with what it was measured under
            let context = RenderHeadroomMemory.Context(
                isStandIn: !isChosenVoiceAudio(engine),
                isInBackground: governor.isAppBackgrounded, generation: request.generation)
            lock.withLock { renderHeadroom.record(chunk.headroom, in: context) }
        }
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
        let (decided, current) = lock.withLock { () -> (Bool?, AVPlayer?) in
            guard transportIntent == .playing else { return (true, nil) }
            if handOverAwaitingStart != nil { return (false, nil) }
            guard !fallbackIsActive else { return (true, nil) }
            guard let live = player else { return (false, nil) }
            return (nil, live)
        }
        if let decided { return decided }
        // The player's rate and clock are read outside `lock` (#2119).
        guard let current else { return false }
        return current.rate > 0 && playerTime(current) >= 0.1
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
        // A downloaded voice's assembled file is named by its engine, so it never replaces James's or Lily's of the same text (#2857).
        let engine = renderer.engine
        let voiceKey = engine == SupertonicNarrationResult.supertonicEngine ? nil : engine
        Task.detached(priority: .utility) { [weak self] in
            do {
                let prepared = try await SupertonicPreparedAudioAssembler.assemble(
                    itemId: snapshot.targetId,
                    sourceText: snapshot.sourceText,
                    projection: snapshot.projection,
                    voice: voice,
                    voiceKey: voiceKey,
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

    private func reportGenerationProgress(completedChunks: Int, totalChunks: Int, restingAhead: Bool = false) {
        let progress = RenderedSpeechGenerationProgress(
            completedChunks: completedChunks,
            totalChunks: totalChunks,
            isRestingAhead: restingAhead
        )
        lock.withLock { reportedProgress = progress }
        onGenerationProgress?(progress)
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

    /// Reads the player's clock. AVFoundation can block here when the media server is slow, so callers read it
    /// outside `lock`: take the player under the lock, release it, then call this (#2119).
    private func playerTime(_ player: AVPlayer?) -> TimeInterval {
        guard let player else { return 0 }
        let seconds = playerClock?(player) ?? player.currentTime().seconds
        guard seconds.isFinite else { return 0 }
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
            if reason == Self.refusedStartReason, rate == 0 {
                Task { @MainActor [weak self, weak changed] in
                    guard let changed else { return }
                    await self?.recoverFromRefusedStart(of: changed)
                }
            }
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

    /// #1681: whether the render chain queues `next` now. Live narration rendered the whole rest of the item ahead,
    /// hot or in the background; now, unless the phone is cool, in front and has power to spare, the chain rests with
    /// `next` held once `RenderAheadPolicy`'s window of listening waits ahead. Playback waiting for a chunk always
    /// renders.
    private func rendersAhead(_ next: RenderRequest) -> Bool {
        let window = renderAheadWindow(), heat = OnDeviceVoiceGovernor.app.supertonicRenderingBlock()
        return lock.withLock {
            guard generation == next.generation else { return true }
            if pendingAutoplayOffset != nil || !defersHeatSwitchLocked(heat)
                && RenderAheadPolicy.rendersNext(listeningAhead: listeningAhead(), window: window, resting: false) {
                // Another chain (a seek's, a gap's) may run beside the resting one: only this chunk wakes it.
                if restingRender?.startOffset == next.startOffset { restingRender = nil }
                return true
            }
            restingRender = next
            return false
        }
    }

    /// Queues the resting chain's chunk again once playback has used half the window, the limit has lifted, or
    /// playback waits for a chunk (#1681).
    private func resumeRenderAheadIfWanted() {
        guard lock.withLock({ restingRender != nil }) else { return }
        let window = renderAheadWindow(), conditions = OnDeviceVoiceGovernor.app.conditions()
        let heat = SpeechEnginePolicy.onDeviceRenderingBlock(conditions)
        let chosenAllowed = onDeviceRenderingAllowed(), backgrounded = governor.isAppBackgrounded
        let woke = lock.withLock { () -> (next: RenderRequest?, progress: RenderedSpeechGenerationProgress)? in
            guard let resting = restingRender else { return nil }
            guard resting.generation == generation else {
                restingRender = nil
                return nil
            }
            let waiting = pendingAutoplayOffset != nil
            let headroom = renderHeadroom.headroom(in: .init(
                isStandIn: OnDeviceRenderAdmission.liveRenderer(chosenAllowed: chosenAllowed,
                    standInHolds: bundledVoiceGeneration == generation, standInAvailable: pressureRenderer != nil) == .standIn,
                isInBackground: backgrounded, generation: generation))
            let resumeAt = window.map { RenderAheadPolicy.resumeMark(window: $0, thermal: conditions.thermal, headroom: headroom) }
            guard waiting || !defersHeatSwitchLocked(heat) && RenderAheadPolicy.rendersNext(
                listeningAhead: listeningAhead(), window: window, resting: true, resumeAt: resumeAt) else {
                return nil
            }
            restingRender = nil
            if !waiting { renderAheadRestarts += 1 }
            let progress = reportedProgress
            // Another chain may have rendered it meanwhile: carry on from the first chunk still missing.
            guard let index = generationRenderOrder.firstIndex(where: { $0.startOffset == resting.startOffset }) else {
                return (resting, progress)
            }
            return (generationRenderOrder[index...].first {
                generationResults[$0.startOffset] == nil && !inFlightOffsets.contains($0.startOffset)
            }, progress)
        }
        guard let woke else { return }
        // Progress is due again: the app's slow-render watch starts from here, not from when the chain rested. A
        // report another chain made meanwhile is newer, so it stands.
        let awake = lock.withLock { () -> RenderedSpeechGenerationProgress? in
            guard reportedProgress == woke.progress, reportedProgress.isRestingAhead else { return nil }
            reportedProgress.isRestingAhead = false
            return reportedProgress
        }
        if let awake { onGenerationProgress?(awake) }
        if let next = woke.next { enqueueRender(next, shouldPlayWhenReady: false) }
    }

    /// #2703: heat refuses Supertonic while it still reads the item and the buffer holds: rest rather than switch.
    private func defersHeatSwitchLocked(_ block: SpeechFallbackReason?) -> Bool {
        pressureRenderer != nil && bundledVoiceGeneration != generation && !fallbackIsActive
            && RenderAheadPolicy.defersHeatSwitch(block: block, listeningAhead: listeningAhead())
    }

    /// #2695: what live narration has waiting now, read by the governor at every budget check. Below
    /// `OnDeviceCPUBudget.liveReserve` ahead, or with the play head waiting on a chunk (a start, a seek or skip, a
    /// render gap), live narration skips the shared background CPU budget, so the budget slows render-ahead but never
    /// lets playback run dry. Pulled, not pushed: a path that moves the play head can't leave a stale answer.
    func liveNarrationBuffer() -> LiveNarrationBuffer {
        lock.withLock {
            LiveNarrationBuffer(
                listeningAhead: listeningAhead(),
                playheadWaitsForAudio: pendingAutoplayOffset != nil
                    || (transportIntent == .playing && startedTargetId == nil))
        }
    }

    /// The listening rendered and waiting past the playing chunk, at the listener's speed: the rendered chunks one
    /// after another from the playing chunk's end (from the playhead before playback starts), those waiting in the
    /// cache and those played once already, which a skip back plays again. Call with `lock` held.
    private func listeningAhead() -> TimeInterval {
        var offset = currentStartOffset + max(0, currentChunkLength)
        var seconds: TimeInterval = 0
        while true {
            if let chunk = renderedCache[offset], chunk.request.sourceLength > 0 {
                seconds += chunk.duration
                offset += chunk.request.sourceLength
            } else if let saved = generationResults[offset], saved.sourceLength > 0,
                      let duration = renderedDurations[offset] {
                seconds += duration
                offset += saved.sourceLength
            } else {
                break
            }
        }
        return RenderAheadPolicy.listening(audioSeconds: seconds, playbackRate: Double(playbackRate))
    }

    /// While the app is away, puts the next rendered chunk on the player behind the playing one, so the seam between
    /// them needs no app code and a backgrounded app that iOS suspends in a silent gap can't stall there (#538).
    /// Runs wherever the answer can change: a chunk starts, a render lands, the app leaves the front, a queued chunk
    /// becomes the playing one. It does nothing when there is nothing to queue.
    private func queueNextChunkIfWanted() {
        guard let applicationIsActive, observesPlayerLifecycle else { return }
        let appIsActive = applicationIsActive()
        lock.withLock {
            // `playing` is the last item on the queue: either the one it is on, or the one it is about to move on
            // to, when the end of the chunk before it was heard first (#1762).
            guard !appIsActive, let queue = player as? AVQueuePlayer, let playing = activeItem,
                  queue.items().last === playing else { return }
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
        // Look under the lock, read the player outside it, then re-check under it before changing anything: the
        // stall monitor calls from another thread, and an AVFoundation read that blocks while holding `lock` would
        // hold up every caller of the client, the main thread included (#2242, as #2119 did for the clock).
        let seen = lock.withLock { () -> (queued: QueuedChunk, active: AVPlayerItem?)? in
            guard let queued = queuedChunk, player === queued.player, activeItem !== queued.item else { return nil }
            return (queued, activeItem)
        }
        guard let seen else { return false }
        let reading = readQueuedPlayer(seen.queued, includesEndFacts: finished != nil && finished === seen.active)
        var finishedURL: URL?
        var replacedObservers: (NSObjectProtocol?, NSKeyValueObservation?)?
        var takeOffQueued: QueuedChunk?
        let applied = lock.withLock { () -> Bool in
            // Something moved while the player was being read (a seek, a new chunk, a stop): that read is stale.
            guard let queued = queuedChunk, queued.item === seen.queued.item, player === queued.player,
                  activeItem === seen.active else { return false }
            let current = reading.current
            if finished != nil, finished === activeItem, current === activeItem {
                // The end of the playing chunk was heard while the player still names it. With the queued chunk
                // still on a player that advances, the queue is moving on to it: the end notification reaches the
                // main thread before `currentItem` does, late when the app is away. Taking it off to start it again
                // through the app played its first words twice at every seam (#1762). Only when it is no longer
                // there, or the player stops at the end, is it not playing: take it off and let the seam go through
                // the app, which still has its audio in the cache.
                let queueMovesOn = BackgroundChunkSeam.queueMovesOnAtEnd(
                    queuedChunkIsOnThePlayer: reading.queuedChunkIsOnThePlayer,
                    playerAdvancesAtItemEnd: reading.playerAdvancesAtItemEnd,
                    playerIsPlaying: reading.playerIsPlaying
                )
                if !queueMovesOn {
                    takeOffQueued = queued
                    return false
                }
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
            // Back to a player that stays on its item at the end, until another chunk is queued behind this one. Not
            // while the player still names the chunk before: it may be about to move on, and `.pause` would stop it.
            if current === queued.item { queued.player.actionAtItemEnd = .pause }
            // The queued chunk's end observer and failure watch take over from the finished chunk's.
            replacedObservers = (playbackEndObserver, playerItemStatusObservation)
            playbackEndObserver = queuedEndObserver
            queuedEndObserver = nil
            playerItemStatusObservation = queuedStatusObservation
            queuedStatusObservation = nil
            return true
        }
        if let takeOff = takeOffQueued {
            // The facts above may be as old as a slow read was long, and the queue could have moved on to the queued
            // chunk since. Taking a chunk off that has started would cut it off, so look again before doing it; if it
            // is current now, catch the bookkeeping up to it here: returning false would send the caller (the end of
            // the chunk before) to start the queued chunk again from the cache, and its first words would play twice.
            if readQueuedPlayer(takeOff, includesEndFacts: false).current === takeOff.item {
                return applyQueuedAdvance(finished: nil)
            }
            lock.withLock {
                guard let queued = queuedChunk, queued.item === takeOff.item else { return }
                queued.player.remove(queued.item)
                queued.player.actionAtItemEnd = .pause
                queuedChunk = nil
            }
            return false
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

    /// The queue player's state, read with no lock held (#2242). The end facts are only needed when the end of the
    /// playing chunk was just heard.
    private func readQueuedPlayer(_ queued: QueuedChunk, includesEndFacts: Bool) -> QueuedPlayerReading {
        if let queuedPlayerReader { return queuedPlayerReader(queued.player, queued.item, includesEndFacts) }
        var reading = QueuedPlayerReading(current: queued.player.currentItem)
        if includesEndFacts {
            reading.queuedChunkIsOnThePlayer = queued.player.items().contains(queued.item)
            reading.playerAdvancesAtItemEnd = queued.player.actionAtItemEnd == .advance
            reading.playerIsPlaying = queued.player.rate != 0
        }
        return reading
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

    /// Whether the app is in the background, not merely inactive (Control Center, a call banner). Off the main thread
    /// it answers "not in the background", which leaves a seam as it was (#1673).
    static func isApplicationInBackground() -> Bool {
        #if canImport(UIKit) && os(iOS)
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { UIApplication.shared.applicationState == .background }
        #else
        return false
        #endif
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

    /// The part of the session setup that changes with the listener's settings.
    private struct ActivatedSessionKey: Equatable {
        let mixes: Bool
        let lowersBackground: Bool
    }

    /// The activation is a synchronous IPC to the audio server that can take hundreds of ms, and it ran on
    /// the main thread at every chunk seam and twice per tap (#2101). It runs again only when the setup
    /// changed, or after anything that can undo it calls `forgetActivatedSession`.
    private func activateAudioSession(forPlayback: Bool = true) throws {
        let key = lock.withLock {
            ActivatedSessionKey(mixes: mixesWithOtherAudio, lowersBackground: lowersBackgroundAudio && forPlayback)
        }
        if lock.withLock({ activatedSessionKey == key }), activatedSessionStillConfigured(for: key) { return }
        let started = ContinuousClock.now
        defer { reportSessionActivation(since: started) }
        if let audioSessionActivator {
            try audioSessionActivator()
            lock.withLock { activatedSessionKey = key }
            return
        }
        #if os(iOS)
        let options = PlaybackAudioSessionPolicy.options(mixes: key.mixes, lowersBackground: key.lowersBackground)
        try PlaybackAudioSessionPolicy.ensurePlaybackCategory(options: options)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        lock.withLock { activatedSessionKey = key }
    }

    /// Another component (a spoken Margin ducking others, a recording) may have changed the category, mode or
    /// options since our activation.
    private func activatedSessionStillConfigured(for key: ActivatedSessionKey) -> Bool {
        #if os(iOS)
        guard audioSessionActivator == nil else { return true }
        let session = AVAudioSession.sharedInstance()
        return session.category == .playback && session.mode == .spokenAudio
            && session.categoryOptions == PlaybackAudioSessionPolicy.options(mixes: key.mixes, lowersBackground: key.lowersBackground)
        #else
        return true
        #endif
    }

    /// The iOS voice sets up and releases the shared session itself, so each call to it ends our activation (#2101).
    private func playFallbackVoice(targetId: String, from offset: Int) throws {
        forgetActivatedSession()
        try fallback.play(targetId: targetId, from: offset)
    }

    private func pauseFallbackVoice() throws {
        forgetActivatedSession()
        try fallback.pause()
    }

    private func stopFallbackVoice() throws {
        forgetActivatedSession()
        try fallback.stop()
    }

    /// Recovery from a stall or a refused start exists to put the session back, so it activates for real: the
    /// session can have gone inactive without telling us, and nothing public can say so (#2101 audit).
    private func reactivateAudioSession() throws {
        forgetActivatedSession()
        try activateAudioSession()
    }

    /// The next activation must run: an interruption, a lost route, a media services reset, a pause or a stop
    /// may have ended or changed the session.
    private func forgetActivatedSession() {
        lock.withLock { activatedSessionKey = nil }
    }

    private func reportSessionActivation(since started: ContinuousClock.Instant) {
        let elapsed = started.duration(to: .now)
        guard elapsed > .milliseconds(20) else { return }
        onStall?("supertonic.session_activate", ["ms": "\(Int(elapsed / .milliseconds(1)))"])
    }

    private func releaseBackgroundAudio() throws {
        #if DEBUG
        lock.withLock { debugBackgroundAudioReleaseCount += 1 }
        #endif
        forgetActivatedSession()
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
            // Our own setCategory posts a category change; forgetting then would undo the activation just made.
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reasonRaw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) != .categoryChange {
                self?.forgetActivatedSession()
            }
            guard let reasonValue = reasonRaw,
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
        forgetActivatedSession()
        let state = lock.withLock { () -> (didPause: Bool, usesFallback: Bool, activePlayer: AVPlayer?) in
            let wasPlaying = transportIntent == .playing
            guard interruptionResume.began(allowsAutomaticResume ? .interruption : .routeLost, wasPlaying: wasPlaying) else {
                return (false, false, nil)
            }
            transportIntent = .paused
            handOverGaps.discardPending()
            return (true, fallbackIsActive, player)
        }
        // A lost route while nothing plays (Bluetooth dropping between listens) isn't worth a log entry.
        if state.didPause || cause != .routeLost { recordSystemPause(cause, acted: state.didPause) }
        guard state.didPause else { return }
        if state.usesFallback {
            try? pauseFallbackVoice()
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
        let requestsResume = lock.withLock {
            interruptionResume.otherAudioStopped(sourceStillPaused: transportIntent == .paused)
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
        let requestsResume = lock.withLock { interruptionResume.ended(shouldResume: shouldResume) }
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
        forgetActivatedSession()
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
            if announcesPause { interruptionResume.cancelAutomaticResume() }
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
            try? stopFallbackVoice()
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
