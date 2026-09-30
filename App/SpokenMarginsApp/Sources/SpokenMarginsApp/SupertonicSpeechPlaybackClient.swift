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

enum RenderedSpeechGenerationState: String, Equatable, Sendable {
    case inactive
    case rendering
    case ready
    case stopped
}

extension RenderedSpeechGenerationState {
    /// The player's on-device voice line. A stop says why (#314).
    func listenerDescription(
        progress: RenderedSpeechGenerationProgress,
        isDelayed: Bool,
        stopReason: String?,
        fallbackReason: SpeechFallbackReason?
    ) -> String {
        switch self {
        case .rendering:
            guard progress.totalChunks > 0 else {
                return "Preparing the full Supertonic audio on this iPhone"
            }
            if isDelayed {
                return "Still rendering chunk \(min(progress.completedChunks + 1, progress.totalChunks)) of \(progress.totalChunks) · \(progress.percent)% complete"
            }
            return "Generating full audio · \(progress.percent)% (\(progress.completedChunks) of \(progress.totalChunks) chunks)"
        case .ready:
            return "Prepared audio is ready for playback"
        case .stopped:
            return SpeechGenerationStopReason.listenerExplanation(stopReason: stopReason, fallbackReason: fallbackReason)
        case .inactive:
            return "On-device voice generation is inactive"
        }
    }
}

struct RenderedSpeechGenerationProgress: Equatable, Sendable {
    var completedChunks: Int
    var totalChunks: Int

    var percent: Int {
        guard totalChunks > 0 else { return 0 }
        return max(0, min(100, Int(
            (Double(completedChunks) / Double(totalChunks) * 100).rounded()
        )))
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
                sessionLoadCount: result.sessionLoadCount
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

    private func cacheURL(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) -> URL {
        // v2: v1 entries can hold iOS-voice stand-ins cached as Supertonic before #311; they now
        // miss once and age out under the cache limit (#363 audit).
        let payload = "supertonic-v2\u{1f}\(voice.rawValue)\u{1f}\(language)\u{1f}\(speed)\u{1f}\(synthesisSteps)\u{1f}\(text)"
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
    /// A stall or its end, with the audio session's and player's state then (#288).
    typealias StallHandler = @Sendable (_ kind: String, _ fields: [String: String]) -> Void
    /// The article text a target speaks, without the engine's spoken preface ("Overview. …").
    typealias ArticleTextLookup = @Sendable (_ targetId: String) -> String?
    /// Which way a play request went, for diagnostics (#235).
    typealias ResumeDecisionHandler = @Sendable (_ fields: [String: String]) -> Void
    /// `stopReason` is set only with `.stopped`: the code that stopped generation (#314).
    typealias GenerationStateHandler = @Sendable (_ state: RenderedSpeechGenerationState, _ stopReason: String?) -> Void
    typealias GenerationProgressHandler = @Sendable (RenderedSpeechGenerationProgress) -> Void
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
    private let onPreparedAudio: PreparedAudioHandler?
    private let preparedChunkLookup: PreparedChunkLookup?
    private let onPreparationPlan: PreparationPlanHandler?
    private let onPreparedChunk: PreparedChunkHandler?
    private let interruptionHandler: InterruptionHandler?
    private let preparedAudioDirectory: URL?
    private let audioSessionNotificationCenter: NotificationCenter
    private let audioSessionActivator: (@Sendable () throws -> Void)?
    private let audioPlayerStarter: (@Sendable (AVPlayer, Float) -> Void)?
    private let observesPlayerLifecycle: Bool
    private let onDeviceRenderingAllowed: @Sendable () -> Bool
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
    private var playbackEndObserver: NSObjectProtocol?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var activeAudioURL: URL?
    private var activeAudioDuration: TimeInterval = 0
    private var generation = UUID()
    private var currentTargetId: String?
    private var currentStartOffset = 0
    private var currentChunkLength = 0
    private var currentChunkBoundary = RenderedSpeechChunkBoundary.hard
    private var fallbackIsActive = false
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
    private var generationRenderOrder: [RenderRequest] = []
    private var generationResults: [Int: SupertonicPreparedChunk] = [:]
    /// Chunks the guard gave to the iOS voice. While any remain, the whole article isn't
    /// assembled into the item's audio, so the next play can try Supertonic again (#363 audit).
    private var standInOffsets: Set<Int> = []
    private var initialPlaybackOffset: Int?
    private var initialRequestedSpokenOffset: Int?
    private var failedRenderReasons: [Int: String] = [:]
    /// Targets in the system voice because of heat or memory pressure (I14: these come back
    /// to Supertonic at the next play once the condition clears).
    private var resourceFallbackTargetIds: Set<String> = []
    private let onRestore: RestoreHandler?
    private let onStall: StallHandler?
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
        onDeviceRenderingAllowed: @escaping @Sendable () -> Bool = { SupertonicResourcePolicy.allowsRendering() },
        fallbackClient: AudioPlaybackClient? = nil,
        interruptionHandler: InterruptionHandler? = nil,
        onGenerationStateChange: GenerationStateHandler? = nil,
        onGenerationProgress: GenerationProgressHandler? = nil,
        onPreparationPlan: PreparationPlanHandler? = nil,
        onPreparedChunk: PreparedChunkHandler? = nil,
        articleText: ArticleTextLookup? = nil,
        preparedChunkLookup: PreparedChunkLookup? = nil,
        onPreparedAudio: PreparedAudioHandler? = nil,
        onFallback: FallbackHandler? = nil,
        onRestore: RestoreHandler? = nil,
        onStall: StallHandler? = nil,
        stallThreshold: Duration = .seconds(5),
        stallSampleInterval: Duration = .seconds(1),
        stallRecoveryCooldown: Duration = .seconds(30),
        onResumeDecision: ResumeDecisionHandler? = nil,
        renderWaitLimit: Duration = .seconds(15)
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
        self.onDeviceRenderingAllowed = onDeviceRenderingAllowed
        self.interruptionHandler = interruptionHandler
        self.maxCharacters = maxCharacters
        self.startupBufferChunkCount = max(1, startupBufferChunkCount)
        self.preparedAudioDirectory = preparedAudioDirectory
        self.onGenerationStateChange = onGenerationStateChange
        self.onGenerationProgress = onGenerationProgress
        self.onPreparationPlan = onPreparationPlan
        self.onPreparedChunk = onPreparedChunk
        self.preparedChunkLookup = preparedChunkLookup
        self.onPreparedAudio = onPreparedAudio
        self.onFallback = onFallback
        self.onRestore = onRestore
        self.onStall = onStall
        self.stallThreshold = stallThreshold
        self.stallSampleInterval = stallSampleInterval
        self.stallRecoveryCooldown = stallRecoveryCooldown
        self.articleText = articleText
        self.onResumeDecision = onResumeDecision
        self.renderWaitLimit = renderWaitLimit
        super.init()
        installAudioSessionObservers()
    }

    deinit {
        playerItemStatusObservation?.invalidate()
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        for observer in audioSessionObservers {
            audioSessionNotificationCenter.removeObserver(observer)
        }
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
                currentTargetId = targetId
                currentStartOffset = spokenOffset
                transportIntent = .playing
            }
            reportGenerationState(
                .stopped,
                stopReason: lock.withLock { generationDisabledReasons[targetId] } ?? SpeechGenerationStopReason.generationDisabledCode
            )
            return
        }
        let spokenOffset = resumeSpokenOffset(targetId: targetId, sourceOffset: charOffset)
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

    /// I14: the chosen voice comes back once the condition that forced the fallback clears.
    /// It switches at a play (resume, seek, next item), never mid-sentence.
    private func restoreOnDeviceRenderingIfConditionCleared(targetId: String) {
        guard lock.withLock({ resourceFallbackTargetIds.contains(targetId) }),
              onDeviceRenderingAllowed() else { return }
        try? fallback.pause()
        lock.withLock {
            resourceFallbackTargetIds.remove(targetId)
            generationDisabledReasons.removeValue(forKey: targetId)
            fallbackIsActive = false
        }
        onRestore?(targetId)
    }

    func currentCharOffset() -> Int? {
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

    /// Supertonic is a user-selected voice. Backgrounding during its initial
    /// two-chunk buffer must never silently change the voice; playback remains
    /// pending until the selected renderer can continue.
    @discardableResult
    func ensurePlaybackStartsBeforeBackgrounding() -> Bool {
        false
    }

    func pause() throws {
        let snapshot = lock.withLock { () -> (Bool, AVPlayer?) in
            transportIntent = .paused
            shouldResumeAfterInterruption = false
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
        removePlaybackEndObserver()
        let stopped = lock.withLock { () -> (urls: [URL], renderControl: RenderTaskControl?) in
            generation = UUID()
            let renderControl = activeRenderControl
            activeRenderControl = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
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
            generationDisabledReasons.removeAll()
            resourceFallbackTargetIds.removeAll()
            generationPlan.removeAll()
            generationRenderOrder.removeAll()
            generationResults.removeAll()
            standInOffsets.removeAll()
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
            player?.replaceCurrentItem(with: nil)
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
            pendingStartTargetId = nil
            startedTargetId = state.1 == .playing ? targetId : nil
            transportIntent = state.1
        }
        reportGenerationState(.stopped, stopReason: stopReason)
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
        guard lock.withLock({ player?.currentItem === item && transportIntent == .playing }) else { return }
        removePlaybackEndObserver()
        let snapshot = lock.withLock { () -> (Int, String?, Int, CachedAudio?, TimeInterval, UUID, URL?) in
            let nextOffset = currentStartOffset + max(1, currentChunkLength)
            // Commit audible progress before detaching the finished player.
            // During an underrun, timeout/fallback and pause/resume must start
            // at the next chunk, not repeat the passage that just finished.
            currentStartOffset = nextOffset
            currentChunkLength = 0
            let cached = cachedOrSavedChunk(containing: nextOffset)
            let finishedURL = activeAudioURL
            player?.replaceCurrentItem(with: nil)
            player = nil
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
                finishedURL
            )
        }
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
            try? releaseBackgroundAudio()
            reportGenerationState(stateAfterPlayback.0, stopReason: stateAfterPlayback.1)
            return
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
            player?.replaceCurrentItem(with: nil)
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
            currentTargetId = targetId
            activeSourceText = preparedSourceText
            currentStartOffset = max(0, min(spokenOffset, source.count))
            currentChunkLength = 0
            transportIntent = .playing
            generationPlan.removeAll()
            generationRenderOrder.removeAll()
            generationResults.removeAll()
            standInOffsets.removeAll()
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
        let plan = spokenPlan.chunks.map {
            RenderRequest(generation: snapshot.generation, targetId: targetId, startOffset: $0.startOffset,
                          sourceLength: $0.sourceLength, text: $0.text, boundary: $0.boundary, articleIndex: $0.articleIndex)
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
        let task = Task { [weak self, renderer, voice] in
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
                    let plan = needsPlan ? self.generationPlan.compactMap { part in
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
                let result: SupertonicNarrationResult
                var performedInference = false
                var ownsResult = false
                let articleChunk = self?.articleChunkPlan(for: request)
                if let articleChunk,
                   let recovered = await self?.preparedChunkLookup?(request.targetId, articleChunk.identity, articleChunk.plan) {
                    result = SupertonicNarrationResult(
                        audioURL: recovered.audioURL,
                        duration: recovered.duration,
                        sampleRate: 0,
                        renderDuration: 0,
                        sessionLoadCount: 0
                    )
                } else if let cached = self?.diskCache?.cachedAudio(
                    text: request.text,
                    voice: voice,
                    language: "en",
                    speed: 1.0,
                    synthesisSteps: 8
                ) {
                    result = cached
                } else {
                    guard self?.onDeviceRenderingAllowed() != false else {
                        await MainActor.run {
                            self?.renderFailed(request: request, shouldPlayWhenReady: shouldPlayWhenReady,
                                               reason: "supertonic_resource_pressure")
                        }
                        return
                    }
                    performedInference = true
                    let rendered = try await renderer.render(
                        text: request.text,
                        voice: voice,
                        language: "en",
                        speed: 1.0,
                        synthesisSteps: 8
                    )
                    // Only Supertonic's own audio is cached under its key. An iOS-voice stand-in
                    // isn't, so the next play renders Supertonic again and re-checks it (#311).
                    if let cache = self?.diskCache,
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
                    if ownsResult { Task { await renderer.discardGeneratedAudio(at: result.audioURL) } }
                    throw CancellationError()
                }
                guard !performedInference || self?.onDeviceRenderingAllowed() != false else {
                    Task { await renderer.discardGeneratedAudio(at: result.audioURL) }
                    await MainActor.run {
                        self?.renderFailed(
                            request: request,
                            shouldPlayWhenReady: shouldPlayWhenReady,
                            reason: "supertonic_resource_pressure"
                        )
                    }
                    return
                }
                await self?.renderCompleted(
                    result: result,
                    request: request,
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
            } else {
                standInOffsets.insert(request.startOffset)
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

    private func activateSystemFallback(targetId: String, sourceOffset: Int, reason: String) {
        let source = lock.withLock { preparedSourceText }
        // The stop names why the iOS voice took over, so the player's line needs nothing else (#314).
        let stopReason = SpeechFallbackReason(
            supertonicCode: reason,
            resourceBlock: SpeechEnginePolicy.onDeviceRenderingBlock(SupertonicResourcePolicy.currentConditions())
        ).rawValue
        do {
            _ = try fallback.prepareSpeechText(source)
            removePlaybackEndObserver()
            let stopped = lock.withLock { () -> (urls: [URL], renderControl: RenderTaskControl?) in
                generation = UUID()
                let renderControl = activeRenderControl
                activeRenderControl = nil
                generationDisabledReasons[targetId] = stopReason
                if reason == "supertonic_resource_pressure" {
                    resourceFallbackTargetIds.insert(targetId)
                } else {
                    resourceFallbackTargetIds.remove(targetId)
                }
                player?.pause()
                player?.replaceCurrentItem(with: nil)
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
                generationPlan.removeAll()
                generationRenderOrder.removeAll()
                generationResults.removeAll()
                standInOffsets.removeAll()
                failedRenderReasons.removeAll()
                initialPlaybackOffset = nil
                initialRequestedSpokenOffset = nil
                preparedAudioAssemblyStarted = false
                return (Array(urls), renderControl)
            }
            stopped.renderControl?.cancel()
            for url in stopped.urls { discardAudio(url) }
            try fallback.play(targetId: targetId, from: sourceOffset)
            let spokenOffset = spokenOffset(forSourceOffset: sourceOffset)
            lock.withLock {
                fallbackIsActive = true
                currentTargetId = targetId
                currentStartOffset = spokenOffset
                currentChunkLength = 0
                pendingStartTargetId = nil
                startedTargetId = targetId
                playbackFailure = nil
                transportIntent = .playing
            }
            reportGenerationState(.stopped, stopReason: stopReason)
            onFallback?(reason, sourceOffset, targetId)
        } catch {
            lock.withLock {
                fallbackIsActive = false
                playbackFailure = "supertonic_and_system_fallback_failed"
                pendingStartTargetId = nil
            }
            try? releaseBackgroundAudio()
        }
    }

    private func playRenderedAudio(
        _ audioURL: URL,
        duration: TimeInterval,
        request: RenderRequest,
        delay: TimeInterval = 0
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
        do {
            // Keep the session continuous between ready chunks so opted-in
            // background audio does not swell at each sentence boundary.
            if lock.withLock({ fallbackIsActive }) { try fallback.stop() }
            let level = lock.withLock { playbackVolume }
            let item = AVPlayerItem(url: audioURL)
            item.audioTimePitchAlgorithm = .timeDomain
            let nextPlayer = AVPlayer(playerItem: item)
            nextPlayer.volume = level
            if observesPlayerLifecycle {
                installPlaybackObservers(for: item, request: request)
            }
            lock.withLock {
                player = nextPlayer
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

    /// Watches the player's clock while playback is intended. AVPlayer can report "playing" while
    /// nothing is heard (#288); a clock that stops moving for `stallThreshold` is logged with the
    /// session's and player's state, and the player is re-seated at the same point. If that doesn't
    /// bring the clock back, playback pauses at the listener's place, so the control shows Play and
    /// one tap resumes (#302). A wait at a chunk boundary (no player) isn't a stall: the render
    /// deadline covers it.
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
                var watchedPlayer: ObjectIdentifier?
                let start = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self else { return }
                    let sample = self.lock.withLock { () -> (active: Bool, intends: Bool, clock: Int?, player: ObjectIdentifier?) in
                        let intends = self.transportIntent == .playing && !self.fallbackIsActive && self.player != nil
                        let time = self.playerTime(self.player)
                        return (self.transportIntent == .playing, intends, self.currentStartOffset * 1_000_000 + Int(time * 1_000),
                                self.player.map(ObjectIdentifier.init))
                    }
                    if sample.player != watchedPlayer {
                        watchedPlayer = sample.player
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
                        await MainActor.run { self.handleStallEvent(event, sampledPlayer: sample.player) }
                    } else if stallOngoing, sample.intends {
                        #if DEBUG
                        self.debugStallWillBeHandled?()
                        #endif
                        await MainActor.run { self.pauseIfReseatDidNotHelp(sampledPlayer: sample.player) }
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

    /// True while the player a stall sample saw is still the one playing. Between the sample and
    /// its handling on the main actor, the listener can switch items; the stall is then stale.
    private func isStillPlaying(_ sampledPlayer: ObjectIdentifier?) -> Bool {
        lock.withLock { transportIntent == .playing && player.map(ObjectIdentifier.init) == sampledPlayer }
    }

    @MainActor
    private func handleStallEvent(_ event: PlaybackStallDetector.Event, sampledPlayer: ObjectIdentifier?) {
        if case .stalled = event, !isStillPlaying(sampledPlayer) { return }
        let player = lock.withLock { self.player }
        var fields = AudioSessionDiagnostics.fields().merging(AudioSessionDiagnostics.fields(for: player)) { first, _ in first }
        switch event {
        case .stalled(_, let forMs):
            fields["stalledMs"] = String(forMs)
            // A second stall inside the cooldown means the last re-seat didn't hold.
            guard claimStallRecovery() else { return pauseStalledPlayback(fields) }
            fields["recovery"] = "reseat_player"
            onStall?("supertonic.stall", fields)
            reseatStalledPlayer()
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
    private func pauseIfReseatDidNotHelp(sampledPlayer: ObjectIdentifier?) {
        guard isStillPlaying(sampledPlayer) else { return }
        let due = lock.withLock { lastStallRecovery.map { ContinuousClock.now - $0 >= stallThreshold } ?? false }
        guard due else { return }
        let player = lock.withLock { self.player }
        pauseStalledPlayback(AudioSessionDiagnostics.fields().merging(AudioSessionDiagnostics.fields(for: player)) { first, _ in first })
    }

    /// Stops showing "playing" for a player that makes no progress (#302). As after a media-services
    /// reset, the player is released with the listener's place and chunk kept, and the app is told
    /// playback paused: the control shows Play, and one tap plays the chunk from that place in a new
    /// player with the session re-activated.
    @MainActor
    private func pauseStalledPlayback(_ fields: [String: String]) {
        var fields = fields
        fields["recovery"] = "paused_for_tap"
        onStall?("supertonic.stall_paused", fields)
        // The tap may land before this monitor samples the pause; it must start a fresh monitor
        // rather than inherit this stall and pause the new player too.
        lock.withLock {
            stallMonitor?.cancel()
            stallMonitor = nil
        }
        markMediaServicesReset()
        // A media-services reset has no session to release; a watchdog pause must stop lowering
        // other apps' audio, as a listener's pause does (#301 audit).
        try? releaseBackgroundAudio()
    }

    /// Re-activates the session and plays the same chunk from the same point in a new player.
    private func reseatStalledPlayer() {
        let snapshot = lock.withLock { () -> (URL, TimeInterval, RenderRequest, TimeInterval)? in
            guard transportIntent == .playing, let request = activeRequest, let url = activeAudioURL else { return nil }
            let time = playerTime(player)
            player?.pause()
            player?.replaceCurrentItem(with: nil)
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
        guard let preparedAudioDirectory, let onPreparedAudio, lock.withLock({ standInOffsets.isEmpty || true }) else {
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
            return playbackRate
        }
        guard let rate else { return }
        do {
            try activateAudioSession()
        } catch {
            activateSystemFallback(request: request, reason: "supertonic_playback_failed")
            return
        }
        if let audioPlayerStarter {
            audioPlayerStarter(nextPlayer, rate)
        } else {
            nextPlayer.playImmediately(atRate: rate)
        }
    }

    private func discardAudio(_ url: URL) {
        if diskCache?.owns(url) == true { return }
        Task { [renderer] in
            await renderer.discardGeneratedAudio(at: url)
        }
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
                player.replaceCurrentItem(with: nil)
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

    private func installPlaybackObservers(for item: AVPlayerItem, request: RenderRequest) {
        removePlaybackEndObserver()
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
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }
    }

    private func playbackItemFailed(_ item: AVPlayerItem, request: RenderRequest) {
        let failedURL = lock.withLock { () -> URL? in
            guard generation == request.generation, player?.currentItem === item else { return nil }
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
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
                self?.pauseForSystemInterruption(allowsAutomaticResume: true)
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
            self?.pauseForSystemInterruption(allowsAutomaticResume: false)
        })
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.markMediaServicesReset()
        })
        #endif
    }

    private func pauseForSystemInterruption(allowsAutomaticResume: Bool) {
        let state = lock.withLock { () -> (didPause: Bool, usesFallback: Bool, activePlayer: AVPlayer?) in
            guard transportIntent == .playing else { return (false, false, nil) }
            transportIntent = .paused
            shouldResumeAfterInterruption = allowsAutomaticResume
            return (true, fallbackIsActive, player)
        }
        guard state.didPause else { return }
        if state.usesFallback {
            try? fallback.pause()
        } else {
            state.activePlayer?.pause()
            try? releaseBackgroundAudio()
        }
        interruptionHandler?(.began)
    }

    private func finishSystemInterruption(shouldResume: Bool) {
        let requestsResume = lock.withLock { () -> Bool in
            defer { shouldResumeAfterInterruption = false }
            return shouldResumeAfterInterruption && shouldResume
        }
        guard requestsResume else { return }
        interruptionHandler?(.endedShouldResume)
    }

    private func markMediaServicesReset() {
        removePlaybackEndObserver()
        let reset = lock.withLock { () -> (
            didPause: Bool,
            interrupted: (url: URL, duration: TimeInterval, targetId: String, chunkStart: Int, generation: UUID)?
        ) in
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
            player?.replaceCurrentItem(with: nil)
            player = nil
            transportIntent = .paused
            shouldResumeAfterInterruption = false
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
        guard let interrupted = reset.interrupted else {
            if reset.didPause { interruptionHandler?(.began) }
            return
        }
        guard let request = renderRequest(
                targetId: interrupted.targetId,
                startOffset: interrupted.chunkStart,
                generation: interrupted.generation
              ) else {
            discardAudio(interrupted.url)
            if reset.didPause { interruptionHandler?(.began) }
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
        if reset.didPause { interruptionHandler?(.began) }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
