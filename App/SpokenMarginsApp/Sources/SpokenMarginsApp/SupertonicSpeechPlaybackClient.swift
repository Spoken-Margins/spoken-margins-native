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
        case playCached(CachedAudio)
        case awaitPendingRender
    }

    private let renderer: any SupertonicRendering
    private let voice: SupertonicVoiceID
    private let fallback: AudioPlaybackClient
    private let diskCache: RenderedSpeechDiskCache?
    private let onFallback: FallbackHandler?
    private let lock = NSLock()
    private let maxCharacters: Int
    private var playbackRate: Float
    private var preparedSourceText = ""
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

    init(
        renderer: any SupertonicRendering,
        voice: SupertonicVoiceID,
        speed: Float,
        fallbackVoiceIdentifier: String?,
        fallbackRate: Float,
        maxCharacters: Int = 240,
        diskCache: RenderedSpeechDiskCache? = nil,
        fallbackClient: AudioPlaybackClient? = nil,
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
        self.maxCharacters = maxCharacters
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
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {
        try setPlaybackRate(Double(rate / 0.5))
        try fallback.configureSpeechSettings(voiceIdentifier: voiceIdentifier, rate: rate)
    }

    func prepareSpeechText(_ text: String) throws -> String {
        let normalized = SpeechTextNormalizer.normalize(text)
        lock.withLock {
            preparedSourceText = normalized
        }
        return normalized
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        try activateAudioSession()
        switch resumeAction(targetId: targetId, from: charOffset) {
        case .resumePlayer(let player):
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
        guard let request = nextRequest(targetId: targetId, from: charOffset) else {
            throw SessionKitError.invalidCommandForState("supertonic_playback_text_empty")
        }
        enqueueRender(request)
    }

    func currentCharOffset() -> Int? {
        let snapshot = lock.withLock {
            (fallbackIsActive, currentStartOffset, currentChunkLength, player, activeAudioDuration)
        }
        if snapshot.0 { return fallback.currentCharOffset() }
        let currentTime = playerTime(snapshot.3)
        guard snapshot.4 > 0, snapshot.2 > 0, currentTime.isFinite else {
            return snapshot.1
        }
        let fraction = max(0, min(1, currentTime / snapshot.4))
        return snapshot.1 + Int((Double(snapshot.2) * fraction).rounded(.down))
    }

    func currentRecoveryCharOffset() -> Int? {
        let usesFallback = lock.withLock { fallbackIsActive }
        return usesFallback ? fallback.currentRecoveryCharOffset() : lock.withLock { currentStartOffset }
    }

    func currentPlaybackPosition() -> PlaybackPosition? {
        let snapshot = lock.withLock {
            (currentTargetId, currentStartOffset, currentChunkLength, playbackRate, preparedSourceText.count)
        }
        guard let targetId = snapshot.0 else { return nil }
        let start = max(0, min(currentCharOffset() ?? snapshot.1, snapshot.4))
        return PlaybackPosition(
            targetType: .itemTextTTS,
            targetId: targetId,
            textStart: start,
            textEnd: min(snapshot.4, max(start + 1, snapshot.1 + snapshot.2)),
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
            return urls
        }
        for url in discarded { discardAudio(url) }
        try fallback.stop()
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
                preparedSourceText.count,
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
            return
        }
        if let cached = snapshot.3 {
            playRenderedAudio(cached.url, duration: cached.duration, request: cached.request, delay: snapshot.4)
        } else {
            lock.withLock { pendingAutoplayOffset = snapshot.0 }
            enqueueRender(request, shouldPlayWhenReady: false)
        }
    }

    private func nextRequest(targetId: String, from charOffset: Int) -> RenderRequest? {
        removePlaybackEndObserver()
        let snapshot = lock.withLock { () -> (String, UUID, [URL]) in
            let source = preparedSourceText
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
            activeSourceText = source
            currentStartOffset = max(0, min(charOffset, source.count))
            currentChunkLength = 0
            transportIntent = .playing
            return (source, nextGeneration, urls)
        }
        for url in snapshot.2 { discardAudio(url) }
        return renderRequest(
            targetId: targetId,
            startOffset: charOffset,
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
        let source = source ?? lock.withLock { preparedSourceText }
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
        activateSystemFallback(request: request, reason: reason)
    }

    private func activateSystemFallback(request: RenderRequest, reason: String) {
        let source = lock.withLock { preparedSourceText }
        do {
            _ = try fallback.prepareSpeechText(source)
            try fallback.play(targetId: request.targetId, from: request.startOffset)
            lock.withLock {
                fallbackIsActive = true
                currentTargetId = request.targetId
                currentStartOffset = request.startOffset
                currentChunkLength = 0
                pendingStartTargetId = nil
                startedTargetId = request.targetId
                playbackFailure = nil
                transportIntent = .playing
            }
            onFallback?(reason, request.startOffset)
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
            installPlaybackObservers(for: item, request: request)
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
            prefetchNextChunk(after: request)
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

    private func prefetchNextChunk(after request: RenderRequest) {
        let snapshot = lock.withLock {
            (preparedSourceText.count, currentTargetId, generation)
        }
        let nextOffset = request.startOffset + max(1, request.sourceLength)
        guard snapshot.2 == request.generation,
              let targetId = snapshot.1,
              nextOffset < snapshot.0,
              let next = renderRequest(
                targetId: targetId,
                startOffset: nextOffset,
                generation: snapshot.2
              ) else { return }
        enqueueRender(next, shouldPlayWhenReady: false)
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
        nextPlayer.playImmediately(atRate: rate)
    }

    private func discardAudio(_ url: URL) {
        if diskCache?.owns(url) == true { return }
        Task { [renderer] in
            await renderer.discardGeneratedAudio(at: url)
        }
    }

    private func resumeAction(targetId: String, from charOffset: Int) -> ResumeAction {
        lock.withLock {
            guard transportIntent == .paused,
                  currentTargetId == targetId,
                  activeSourceText == preparedSourceText else { return .none }
            let chunkEnd = currentStartOffset + max(0, currentChunkLength)
            if let player, charOffset >= currentStartOffset, charOffset <= chunkEnd {
                transportIntent = .playing
                pendingStartTargetId = nil
                startedTargetId = targetId
                return .resumePlayer(player)
            }
            if let cached = renderedCache.removeValue(forKey: charOffset) {
                transportIntent = .playing
                pendingStartTargetId = targetId
                return .playCached(cached)
            }
            if inFlightOffsets.contains(charOffset) {
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
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    private func installAudioSessionObservers() {
        #if os(iOS)
        let center = NotificationCenter.default
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
            object: AVAudioSession.sharedInstance(),
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
