import AVFoundation
import CryptoKit
import Foundation
import SessionKit
import SessionKitAudio
import SessionKitSupertonic

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

enum RenderedSpeechChunkBoundary: String, Sendable {
    case sentence
    case comma
    case whitespace
    case hard

    var transitionDelay: TimeInterval {
        switch self {
        case .sentence: 0.12
        case .comma: 0.05
        case .whitespace, .hard: 0
        }
    }
}

enum RenderedSpeechGenerationState: String, Equatable, Sendable {
    case inactive
    case rendering
    case ready
    case stopped
}

struct RenderedSpeechSourceSlice: Equatable, Sendable {
    var text: String
    var sourceLength: Int
    var boundary: RenderedSpeechChunkBoundary
}

enum RenderedSpeechChunker {
    static func sourceSlice(
        from source: String,
        startOffset: Int,
        maxCharacters: Int = 240
    ) -> RenderedSpeechSourceSlice {
        let clampedOffset = max(0, min(startOffset, source.count))
        let start = source.index(source.startIndex, offsetBy: clampedOffset)
        let remainingLength = source.distance(from: start, to: source.endIndex)
        let length = min(maxCharacters, remainingLength)
        let hardEnd = source.index(start, offsetBy: length)
        return selectChunkPrefix(String(source[start..<hardEnd]), maxCharacters: maxCharacters)
    }

    static func selectChunkPrefix(
        _ prefix: String,
        maxCharacters: Int = 240
    ) -> RenderedSpeechSourceSlice {
        let minimumUsefulLength = min(80, max(24, maxCharacters / 3))
        let sentenceCharacters = CharacterSet(charactersIn: ".!?\n;:")
        if let sentence = boundary(
            in: prefix,
            characters: sentenceCharacters,
            includeBoundary: true,
            minimumUsefulLength: minimumUsefulLength
        ) {
            return sentence.withBoundary(.sentence)
        }
        if let comma = boundary(
            in: prefix,
            characters: CharacterSet(charactersIn: ","),
            includeBoundary: true,
            minimumUsefulLength: minimumUsefulLength
        ) {
            return comma.withBoundary(.comma)
        }
        if let whitespace = boundary(
            in: prefix,
            characters: .whitespacesAndNewlines,
            includeBoundary: false,
            minimumUsefulLength: minimumUsefulLength
        ) {
            return whitespace.withBoundary(.whitespace)
        }
        let normalized = SpeechTextNormalizer.normalize(prefix)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RenderedSpeechSourceSlice(
            text: normalized,
            sourceLength: prefix.count,
            boundary: .hard
        )
    }

    private static func boundary(
        in prefix: String,
        characters: CharacterSet,
        includeBoundary: Bool,
        minimumUsefulLength: Int
    ) -> RenderedSpeechSourceSlice? {
        guard let range = prefix.rangeOfCharacter(from: characters, options: .backwards) else {
            return nil
        }
        let end = includeBoundary ? range.upperBound : range.lowerBound
        guard prefix.distance(from: prefix.startIndex, to: end) >= minimumUsefulLength else {
            return nil
        }
        let selected = String(prefix[..<end])
        let normalized = SpeechTextNormalizer.normalize(selected)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return RenderedSpeechSourceSlice(
            text: normalized,
            sourceLength: prefix.distance(from: prefix.startIndex, to: range.upperBound),
            boundary: .hard
        )
    }
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
        let payload = "supertonic-v1\u{1f}\(voice.rawValue)\u{1f}\(language)\u{1f}\(speed)\u{1f}\(synthesisSteps)\u{1f}\(text)"
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

private extension RenderedSpeechSourceSlice {
    func withBoundary(_ boundary: RenderedSpeechChunkBoundary) -> Self {
        .init(text: text, sourceLength: sourceLength, boundary: boundary)
    }
}

final class SupertonicSpeechPlaybackClient: NSObject, AudioPlaybackClient, @unchecked Sendable {
    typealias FallbackHandler = @Sendable (_ reason: String, _ charOffset: Int) -> Void
    typealias GenerationStateHandler = @Sendable (RenderedSpeechGenerationState) -> Void

    private struct RenderRequest: Sendable {
        var generation: UUID
        var targetId: String
        var startOffset: Int
        var sourceLength: Int
        var text: String
        var boundary: RenderedSpeechChunkBoundary
    }

    private struct CachedAudio {
        var url: URL
        var duration: TimeInterval
        var request: RenderRequest
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
    }

    private let renderer: any SupertonicRendering
    private let voice: SupertonicVoiceID
    private let fallback: AudioPlaybackClient
    private let diskCache: RenderedSpeechDiskCache?
    private let onFallback: FallbackHandler?
    private let onGenerationStateChange: GenerationStateHandler?
    private let audioSessionNotificationCenter: NotificationCenter
    private let audioSessionActivator: (@Sendable () throws -> Void)?
    private let audioPlayerStarter: (@Sendable (AVPlayer, Float) -> Void)?
    private let observesPlayerLifecycle: Bool
    private let lock = NSLock()
    private let maxCharacters: Int
    private let minimumPrefetchDepth: Int
    private let underrunFallbackDelay: Duration
    private var playbackRate: Float
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
    private var generationDisabledTargetIds = Set<String>()

    init(
        renderer: any SupertonicRendering,
        voice: SupertonicVoiceID,
        speed: Float,
        fallbackVoiceIdentifier: String?,
        fallbackRate: Float,
        maxCharacters: Int = 240,
        minimumPrefetchDepth: Int = 2,
        underrunFallbackDelay: Duration = .milliseconds(750),
        diskCache: RenderedSpeechDiskCache? = nil,
        audioSessionNotificationCenter: NotificationCenter = .default,
        audioSessionActivator: (@Sendable () throws -> Void)? = nil,
        audioPlayerStarter: (@Sendable (AVPlayer, Float) -> Void)? = nil,
        observesPlayerLifecycle: Bool = true,
        fallbackClient: AudioPlaybackClient? = nil,
        onGenerationStateChange: GenerationStateHandler? = nil,
        onFallback: FallbackHandler? = nil
    ) {
        self.renderer = renderer
        self.voice = voice
        self.playbackRate = max(0.7, min(2.0, speed))
        self.fallback = fallbackClient ?? SystemSpeechPlaybackClient(
            voiceIdentifier: fallbackVoiceIdentifier,
            speechRate: fallbackRate
        )
        self.diskCache = diskCache
        self.audioSessionNotificationCenter = audioSessionNotificationCenter
        self.audioSessionActivator = audioSessionActivator
        self.audioPlayerStarter = audioPlayerStarter
        self.observesPlayerLifecycle = observesPlayerLifecycle
        self.maxCharacters = maxCharacters
        self.minimumPrefetchDepth = max(1, minimumPrefetchDepth)
        self.underrunFallbackDelay = underrunFallbackDelay
        self.onGenerationStateChange = onGenerationStateChange
        self.onFallback = onFallback
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
        reportGenerationState(.inactive)
        return projection.text
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        try activateAudioSession()
        let usesStoppedGeneration = lock.withLock {
            generationDisabledTargetIds.contains(targetId)
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
            reportGenerationState(.stopped)
            return
        }
        let spokenOffset = spokenOffset(forSourceOffset: charOffset)
        switch resumeAction(targetId: targetId, fromSpokenOffset: spokenOffset) {
        case .resumePlayer(let player):
            player.playImmediately(atRate: lock.withLock { playbackRate })
            return
        case .seekPlayer(let player, let time):
            player.pause()
            player.seek(
                to: CMTime(seconds: time, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            player.playImmediately(atRate: lock.withLock { playbackRate })
            return
        case .playCached(let cached):
            playRenderedAudio(cached.url, duration: cached.duration, request: cached.request)
            return
        case .awaitPendingRender:
            return
        case .none:
            break
        }
        guard let request = nextRequest(targetId: targetId, fromSpokenOffset: spokenOffset) else {
            throw SessionKitError.invalidCommandForState("supertonic_playback_text_empty")
        }
        enqueueRender(request)
    }

    func currentCharOffset() -> Int? {
        let snapshot = lock.withLock {
            (
                fallbackIsActive,
                currentStartOffset,
                currentChunkLength,
                player,
                activeAudioDuration,
                preparedSpeechProjection
            )
        }
        if snapshot.0 { return fallback.currentCharOffset() }
        let currentTime = playerTime(snapshot.3)
        guard snapshot.4 > 0, snapshot.2 > 0, currentTime.isFinite else {
            return snapshot.5.sourceOffset(atSpokenCharacterOffset: snapshot.1)
        }
        let fraction = max(0, min(1, currentTime / snapshot.4))
        let spokenOffset = snapshot.1 + Int((Double(snapshot.2) * fraction).rounded(.down))
        return snapshot.5.sourceOffset(atSpokenCharacterOffset: spokenOffset)
    }

    func currentRecoveryCharOffset() -> Int? {
        let snapshot = lock.withLock {
            (fallbackIsActive, currentStartOffset, preparedSpeechProjection)
        }
        return snapshot.0
            ? fallback.currentRecoveryCharOffset()
            : snapshot.2.sourceOffset(atSpokenCharacterOffset: snapshot.1)
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
        let clamped = Float(max(0.5, min(2.0, rate)))
        let activePlayer = lock.withLock { () -> AVPlayer? in
            playbackRate = clamped
            return transportIntent == .playing ? player : nil
        }
        if activePlayer?.timeControlStatus == .playing {
            activePlayer?.rate = clamped
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
                pendingStartTargetId == targetId || pendingAutoplayOffset != nil || !inFlightOffsets.isEmpty
            )
        }
        if snapshot.0 { return fallback.playbackStartStatus(targetId: targetId) }
        if let failure = snapshot.1 { return .failed(failure) }
        if snapshot.2 { return .confirmed }
        return snapshot.3 ? .pending : .confirmed
    }

    /// On-device rendering may be suspended before it produces the first audio
    /// buffer. When the app is leaving the foreground, switch an unconfirmed
    /// start to the system speech client so background audio actually begins.
    @discardableResult
    func ensurePlaybackStartsBeforeBackgrounding() -> Bool {
        let pending = lock.withLock { () -> (targetId: String, startOffset: Int)? in
            guard !fallbackIsActive,
                  transportIntent == .playing,
                  startedTargetId == nil,
                  let targetId = currentTargetId else {
                return nil
            }
            generation = UUID()
            inFlightOffsets.removeAll()
            pendingAutoplayOffset = nil
            pendingStartTargetId = targetId
            playbackFailure = nil
            return (targetId, currentStartOffset)
        }
        guard let pending else { return false }
        let sourceOffset = sourceOffset(forSpokenOffset: pending.startOffset)
        activateSystemFallback(
            targetId: pending.targetId,
            sourceOffset: sourceOffset,
            reason: "background_during_initial_render"
        )
        return true
    }

    func pause() throws {
        let snapshot = lock.withLock { () -> (Bool, AVPlayer?) in
            transportIntent = .paused
            return (fallbackIsActive, player)
        }
        if snapshot.0 {
            try fallback.pause()
        } else {
            snapshot.1?.pause()
        }
    }

    func playbackTransportState(targetId: String) -> PlaybackTransportState? {
        let snapshot = lock.withLock {
            (fallbackIsActive, currentTargetId, transportIntent, playbackFailure, playbackComplete, player, !inFlightOffsets.isEmpty)
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
        case .paused: return snapshot.6 ? .waiting : .paused
        case nil: return snapshot.6 ? .waiting : .stopped
        @unknown default: return nil
        }
    }

    func stop() throws {
        removePlaybackEndObserver()
        let discarded = lock.withLock { () -> [URL] in
            generation = UUID()
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            fallbackIsActive = false
            let urls = renderedCache.values.map(\.url) + [activeAudioURL].compactMap { $0 }
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
            generationDisabledTargetIds.removeAll()
            return urls
        }
        for url in discarded { discardAudio(url) }
        try fallback.stop()
        reportGenerationState(.inactive)
    }

    /// Stops scheduling on-device synthesis for the current item and keeps
    /// playback moving with the iOS system voice. The synchronous ONNX call
    /// already in progress cannot be interrupted, but its result is discarded
    /// and no following chunk is scheduled.
    @discardableResult
    func stopOnDeviceRenderingAndUseSystemSpeech() throws -> Bool {
        let offset = currentCharOffset() ?? currentRecoveryCharOffset() ?? 0
        let state = lock.withLock { (currentTargetId, transportIntent, fallbackIsActive) }
        guard let targetId = state.0 else { return false }
        if state.2 {
            _ = lock.withLock { generationDisabledTargetIds.insert(targetId) }
            reportGenerationState(.stopped)
            return true
        }

        _ = try fallback.prepareSpeechText(lock.withLock { preparedSourceText })
        let spokenOffset = spokenOffset(forSourceOffset: offset)
        removePlaybackEndObserver()
        let discarded = lock.withLock { () -> [URL] in
            generation = UUID()
            generationDisabledTargetIds.insert(targetId)
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            let urls = renderedCache.values.map(\.url) + [activeAudioURL].compactMap { $0 }
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
            return urls
        }
        for url in discarded { discardAudio(url) }

        try fallback.play(targetId: targetId, from: offset)
        if state.1 == .paused {
            try fallback.pause()
        }
        lock.withLock {
            pendingStartTargetId = nil
            startedTargetId = state.1 == .playing ? targetId : nil
            transportIntent = state.1
        }
        reportGenerationState(.stopped)
        return true
    }

    private func playbackItemFinished(_ item: AVPlayerItem) {
        guard lock.withLock({ player?.currentItem === item && transportIntent == .playing }) else { return }
        removePlaybackEndObserver()
        let snapshot = lock.withLock { () -> (Int, String?, Int, CachedAudio?, TimeInterval, UUID, URL?) in
            let nextOffset = currentStartOffset + max(1, currentChunkLength)
            let cached = renderedCache.removeValue(forKey: nextOffset)
            let finishedURL = activeAudioURL
            player?.replaceCurrentItem(with: nil)
            player = nil
            activeAudioURL = nil
            activeAudioDuration = 0
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
        if let finishedURL = snapshot.6 { discardAudio(finishedURL) }
        guard let targetId = snapshot.1,
              snapshot.0 < snapshot.2,
              let request = renderRequest(targetId: targetId, startOffset: snapshot.0, generation: snapshot.5) else {
            lock.withLock {
                currentStartOffset = snapshot.2
                currentChunkLength = 0
                completedTargetId = snapshot.1
                playbackComplete = true
                transportIntent = .stopped
            }
            reportGenerationState(.inactive)
            return
        }
        if let cached = snapshot.3 {
            playRenderedAudio(cached.url, duration: cached.duration, request: cached.request, delay: snapshot.4)
        } else {
            lock.withLock { pendingAutoplayOffset = snapshot.0 }
            enqueueRender(request, shouldPlayWhenReady: false)
            scheduleUnderrunFallback(
                targetId: targetId,
                spokenOffset: snapshot.0,
                generation: snapshot.5
            )
        }
    }

    private func nextRequest(targetId: String, fromSpokenOffset spokenOffset: Int) -> RenderRequest? {
        removePlaybackEndObserver()
        let snapshot = lock.withLock { () -> (String, UUID, [URL]) in
            let source = preparedSpeechProjection.text
            generation = UUID()
            let nextGeneration = generation
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            fallbackIsActive = false
            let urls = renderedCache.values.map(\.url) + [activeAudioURL].compactMap { $0 }
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
            return (source, nextGeneration, urls)
        }
        for url in snapshot.2 { discardAudio(url) }
        return renderRequest(
            targetId: targetId,
            startOffset: spokenOffset,
            generation: snapshot.1,
            source: snapshot.0
        )
    }

    private func renderRequest(
        targetId: String,
        startOffset: Int,
        generation: UUID,
        source: String? = nil
    ) -> RenderRequest? {
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
        let shouldStart = lock.withLock { () -> Bool in
            if renderedCache[request.startOffset] != nil || inFlightOffsets.contains(request.startOffset) {
                return false
            }
            inFlightOffsets.insert(request.startOffset)
            return true
        }
        guard shouldStart else { return }
        reportGenerationState(.rendering)
        Task { [weak self, renderer, voice] in
            do {
                let result: SupertonicNarrationResult
                if let cached = self?.diskCache?.cachedAudio(
                    text: request.text,
                    voice: voice,
                    language: "en",
                    speed: 1.0,
                    synthesisSteps: 8
                ) {
                    result = cached
                } else {
                    let rendered = try await renderer.render(
                        text: request.text,
                        voice: voice,
                        language: "en",
                        speed: 1.0,
                        synthesisSteps: 8
                    )
                    if let cache = self?.diskCache,
                       let retained = try? cache.store(
                            rendered,
                            text: request.text,
                            voice: voice,
                            language: "en",
                            speed: 1.0,
                            synthesisSteps: 8
                       ) {
                        await renderer.discardGeneratedAudio(at: rendered.audioURL)
                        result = retained
                    } else {
                        result = rendered
                    }
                }
                await MainActor.run {
                    self?.renderCompleted(
                        result: result,
                        request: request,
                        shouldPlayWhenReady: shouldPlayWhenReady
                    )
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
    }

    private func renderCompleted(
        result: SupertonicNarrationResult,
        request: RenderRequest,
        shouldPlayWhenReady: Bool
    ) {
        let action = lock.withLock { () -> (valid: Bool, autoplay: Bool) in
            inFlightOffsets.remove(request.startOffset)
            guard generation == request.generation else { return (false, false) }
            let requestedAutoplay = shouldPlayWhenReady || pendingAutoplayOffset == request.startOffset
            let autoplay = requestedAutoplay && transportIntent == .playing
            if autoplay {
                pendingAutoplayOffset = nil
            } else {
                renderedCache[request.startOffset] = CachedAudio(
                    url: result.audioURL,
                    duration: result.duration,
                    request: request
                )
            }
            return (true, autoplay)
        }
        guard action.valid else {
            discardAudio(result.audioURL)
            return
        }
        reportGenerationState(.ready)
        if action.autoplay {
            playRenderedAudio(result.audioURL, duration: result.duration, request: request)
        }
    }

    private func renderFailed(
        request: RenderRequest,
        shouldPlayWhenReady: Bool,
        reason: String
    ) {
        let shouldFallback = lock.withLock { () -> Bool in
            inFlightOffsets.remove(request.startOffset)
            let awaited = pendingAutoplayOffset == request.startOffset
            if awaited { pendingAutoplayOffset = nil }
            return generation == request.generation
                && transportIntent == .playing
                && (shouldPlayWhenReady || awaited)
        }
        guard shouldFallback else { return }
        reportGenerationState(.stopped)
        activateSystemFallback(request: request, reason: reason)
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
        do {
            _ = try fallback.prepareSpeechText(source)
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
            reportGenerationState(.stopped)
            onFallback?(reason, sourceOffset)
        } catch {
            lock.withLock {
                fallbackIsActive = false
                playbackFailure = "supertonic_and_system_fallback_failed"
                pendingStartTargetId = nil
            }
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
            try fallback.stop()
            try activateAudioSession()
            let item = AVPlayerItem(url: audioURL)
            item.audioTimePitchAlgorithm = .timeDomain
            let nextPlayer = AVPlayer(playerItem: item)
            if observesPlayerLifecycle {
                installPlaybackObservers(for: item, request: request)
            }
            lock.withLock {
                player = nextPlayer
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
            prefetchFollowingChunks(after: request)
            if delay > 0 {
                Task { @MainActor [weak self, weak nextPlayer, weak item] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let nextPlayer, let item else { return }
                    self?.startPlayer(nextPlayer, item: item, request: request)
                }
            } else {
                startPlayer(nextPlayer, item: item, request: request)
            }
        } catch {
            diskCache?.invalidate(audioURL)
            discardAudio(audioURL)
            activateSystemFallback(request: request, reason: "supertonic_playback_failed")
        }
    }

    private func prefetchFollowingChunks(after request: RenderRequest) {
        let snapshot = lock.withLock {
            (
                preparedSpeechProjection.text.count,
                currentTargetId,
                generation,
                generationDisabledTargetIds.contains(request.targetId),
                playbackRate
            )
        }
        guard !snapshot.3,
              snapshot.2 == request.generation,
              let targetId = snapshot.1 else { return }
        let rateAwareDepth = Int(ceil(Double(snapshot.4))) + 1
        let depth = max(minimumPrefetchDepth, rateAwareDepth)
        var nextOffset = request.startOffset + max(1, request.sourceLength)
        for _ in 0..<depth {
            guard nextOffset < snapshot.0,
                  let next = renderRequest(
                    targetId: targetId,
                    startOffset: nextOffset,
                    generation: snapshot.2
                  ) else { break }
            enqueueRender(next, shouldPlayWhenReady: false)
            nextOffset += max(1, next.sourceLength)
        }
    }

    private func scheduleUnderrunFallback(
        targetId: String,
        spokenOffset: Int,
        generation expectedGeneration: UUID
    ) {
        let delay = underrunFallbackDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await MainActor.run {
                self?.recoverFromRenderUnderrun(
                    targetId: targetId,
                    spokenOffset: spokenOffset,
                    generation: expectedGeneration
                )
            }
        }
    }

    private func recoverFromRenderUnderrun(
        targetId: String,
        spokenOffset: Int,
        generation expectedGeneration: UUID
    ) {
        let discarded = lock.withLock { () -> [URL]? in
            guard generation == expectedGeneration,
                  currentTargetId == targetId,
                  transportIntent == .playing,
                  !fallbackIsActive,
                  pendingAutoplayOffset == spokenOffset else { return nil }
            generation = UUID()
            generationDisabledTargetIds.insert(targetId)
            pendingAutoplayOffset = nil
            inFlightOffsets.removeAll()
            pendingStartTargetId = targetId
            startedTargetId = nil
            let urls = renderedCache.values.map(\.url)
            renderedCache.removeAll()
            return urls
        }
        guard let discarded else { return }
        for url in discarded { discardAudio(url) }
        activateSystemFallback(
            targetId: targetId,
            sourceOffset: sourceOffset(forSpokenOffset: spokenOffset),
            reason: "supertonic_buffer_underrun"
        )
    }

    private func reportGenerationState(_ state: RenderedSpeechGenerationState) {
        onGenerationStateChange?(state)
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

    private func resumeAction(targetId: String, fromSpokenOffset spokenOffset: Int) -> ResumeAction {
        lock.withLock {
            guard transportIntent == .paused,
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
                if abs(currentOffset - spokenOffset) <= 1 {
                    return .resumePlayer(player)
                }
                let fraction = Double(spokenOffset - currentStartOffset) / Double(max(1, currentChunkLength))
                return .seekPlayer(player, max(0, min(activeAudioDuration, activeAudioDuration * fraction)))
            }
            if let cached = renderedCache.removeValue(forKey: spokenOffset) {
                transportIntent = .playing
                pendingStartTargetId = targetId
                return .playCached(cached)
            }
            if inFlightOffsets.contains(spokenOffset) {
                transportIntent = .playing
                pendingStartTargetId = targetId
                return .awaitPendingRender
            }
            return .none
        }
    }

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
        activateSystemFallback(request: request, reason: "supertonic_playback_failed")
    }

    private func activateAudioSession() throws {
        if let audioSessionActivator {
            try audioSessionActivator()
            return
        }
        #if os(iOS)
        // Now Playing eligibility requires a non-mixable playback session.
        // `.duckOthers` implicitly makes this session mixable, which lets audio
        // play while preventing iOS from promoting the app to the system media
        // controls.
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try AVAudioSession.sharedInstance().setActive(true)
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
                  AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
            self?.pauseForSystemInterruption()
        })
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable else { return }
            self?.pauseForSystemInterruption()
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

    private func pauseForSystemInterruption() {
        let activePlayer = lock.withLock { () -> AVPlayer? in
            guard transportIntent == .playing else { return nil }
            transportIntent = .paused
            return player
        }
        activePlayer?.pause()
    }

    private func markMediaServicesReset() {
        removePlaybackEndObserver()
        let interrupted = lock.withLock { () -> (URL, TimeInterval, String, Int, UUID)? in
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            transportIntent = .paused
            playbackFailure = nil
            pendingStartTargetId = nil
            startedTargetId = nil
            guard let url = activeAudioURL,
                  activeAudioDuration > 0,
                  let targetId = currentTargetId else { return nil }
            let value = (url, activeAudioDuration, targetId, currentStartOffset, generation)
            activeAudioURL = nil
            activeAudioDuration = 0
            return value
        }
        guard let interrupted else { return }
        guard let request = renderRequest(
                targetId: interrupted.2,
                startOffset: interrupted.3,
                generation: interrupted.4
              ) else {
            discardAudio(interrupted.0)
            return
        }
        let retained = lock.withLock { () -> Bool in
            guard generation == interrupted.4,
                  currentTargetId == interrupted.2,
                  transportIntent == .paused else { return false }
            renderedCache[interrupted.3] = CachedAudio(
                url: interrupted.0,
                duration: interrupted.1,
                request: request
            )
            return true
        }
        if !retained { discardAudio(interrupted.0) }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
