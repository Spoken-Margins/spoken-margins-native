import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// What each engine call a background job's completion makes on the main thread costs on the Library-sized fixture
/// (#2509, #2256): wall time by `ContinuousClock`, and the rows and bytes the read meter saw. It is the source of the
/// numbers on the `Stays:` rows of `scripts/main_thread_reads_baseline.json`.
///
/// Rerun: `SESSIONKIT_READ_COST=1 swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter EngineCompletionCostTests`
/// in `Packages/SessionKit`; `SESSIONKIT_ENGINE_COST_TABLE=<file>` also writes the table. It skips otherwise: building
/// the Library takes about 10 s. `-DDEBUG` is there because another test target needs debug-only members to compile.
final class EngineCompletionCostTests: XCTestCase {
    func testTheCostOfEachCompletionCall() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SESSIONKIT_READ_COST"] == "1" || environment["SESSIONKIT_ENGINE_COST_TABLE"] != nil else {
            throw XCTSkip("Set SESSIONKIT_READ_COST=1 to build the Library fixture and measure")
        }
        let fixture = try LibraryFixture.build(.library)
        defer { fixture.remove() }
        let bench = EngineCostBench(fixture: fixture)
        try bench.prepareRecords()
        try bench.measureEveryCall()
        let table = bench.markdown()
        print(table)
        if let path = environment["SESSIONKIT_ENGINE_COST_TABLE"] { try table.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}

/// The scenarios, on real files. Each run gets a new engine (as a launch builds one) so a primed cache is the only
/// state carried in; the setup is not timed.
final class EngineCostBench {
    struct Row { var name: String; var ms: Double; var worstMs: Double; var rows: Int; var bytes: Int; var reads: String }

    let fixture: LibraryFixture
    private(set) var rows: [Row] = []
    private let meter = StoreReadMeter()
    private let runs = 7

    static let longItemId = "item-long-episode"
    static let longSessionId = "session-long-episode"
    static let longDurationMs = 180 * 60 * 1000
    static let mappedURL = "https://cdn.example.com/mapped.mp3"
    static let longURL = "https://cdn.example.com/long.mp3"
    static let bookSessionId = "session-book"
    static let articleSessionId = "session-article"
    static let summaryTurnId = "turn-summary"
    static let summaryJobId = "job-summary"

    init(fixture: LibraryFixture) { self.fixture = fixture }

    var bookItemId: String { fixture.itemIds.last! }
    var articleItemId: String { fixture.articleItemId }

    static func profile() -> RuntimeCapabilityProfile {
        RuntimeCapabilityProfile(
            id: "phone", displayName: "Phone",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media", "prerendered_audio"],
                           "ai": ["generate_listening_map"]])
    }

    /// A transcript like the fixture's: one segment about every 4 seconds, about 220 bytes each.
    static func timeline(durationMs: Int) -> TranscriptTimeline {
        var random = SplitMix64(seed: UInt64(durationMs))
        let count = durationMs / LibraryFixture.mappedSegmentMs
        var offset = 0
        var segments: [MediaTimelineSegment] = []
        segments.reserveCapacity(count)
        for index in 0..<count {
            let text = LibraryFixture.prose(bytes: 220, random: &random)
            segments.append(MediaTimelineSegment(
                id: "seg-\(index)", startMs: index * LibraryFixture.mappedSegmentMs, endMs: (index + 1) * LibraryFixture.mappedSegmentMs,
                startChar: offset, endChar: offset + text.count, text: text))
            offset += text.count + 1
        }
        return MediaTimeline(segments: segments, chapters: [], durationMs: durationMs)
    }

    /// Audio prepared for a text: a segment about every 400 characters.
    static func prepared(text: String) -> PreparedTextAudio {
        var segments: [MediaTimelineSegment] = []
        var start = 0
        let total = text.count
        while start < total {
            let end = min(total, start + 400)
            segments.append(MediaTimelineSegment(
                id: "p-\(segments.count)", startMs: segments.count * 25_000, endMs: (segments.count + 1) * 25_000,
                startChar: start, endChar: end, text: ""))
            start = end
        }
        let duration = segments.count * 25_000
        return PreparedTextAudio(
            normalizedText: text,
            media: ItemMedia(sourceType: .generatedTTSPrerendered, url: "file:///prepared/audio.caf", durationMs: duration),
            timeline: MediaTimeline(segments: segments, chapters: [], durationMs: duration))
    }

    func prepareRecords() throws {
        let store = try fixture.openStore()
        // The mapped podcast as a downloaded episode, and a session on it.
        var mapped = try store.loadItem(id: LibraryFixture.mappedItemId)
        mapped.mediaType = TargetType.transcriptBackedMedia.rawValue
        mapped.media = ItemMedia(sourceType: .nativeMediaFile, url: Self.mappedURL, durationMs: LibraryFixture.mappedDurationMs)
        try store.saveItem(mapped)
        var session = try XCTUnwrap(store.loadSession(id: "session-0"))
        session.currentTargetType = .transcriptBackedMedia
        session.currentTargetId = Self.mappedURL
        session.position = Position(mediaTimeMs: 1_000_000)
        try store.saveSession(session)

        // The longest realistic episode: three hours, with its transcript.
        try store.saveItem(Item(
            id: Self.longItemId, title: "Three hour episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: Self.longURL, durationMs: Self.longDurationMs)))
        try store.saveSession(Session(
            id: Self.longSessionId, itemId: Self.longItemId, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: Self.longURL,
            position: Position(mediaTimeMs: 1_000_000), completionPercent: 1, playbackRate: 1))
        try store.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "timeline-long", itemId: Self.longItemId, createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            timeline: Self.timeline(durationMs: Self.longDurationMs)))

        // Sessions on the article and on the largest book, each with 20 Margins and 20 saved replies.
        for (sessionId, itemId) in [(Self.articleSessionId, articleItemId), (Self.bookSessionId, bookItemId)] {
            try store.saveSession(Session(
                id: sessionId, itemId: itemId, status: "in_progress", phase: .itemPlayback,
                currentTargetType: .itemTextTTS, currentTargetId: itemId,
                position: Position(charOffset: 10_000), completionPercent: 1, playbackRate: 1))
            var random = SplitMix64(seed: 42)
            for index in 0..<20 {
                try store.saveInterjection(Interjection(
                    id: "\(sessionId)-margin-\(index)", itemId: itemId, sessionId: sessionId, targetType: .item, targetId: itemId,
                    createdAt: Date(timeIntervalSince1970: 1_760_000_000), roughPercent: 1,
                    anchor: Anchor(anchorType: .text, startChar: index, endChar: index + 1, anchorBefore: "", anchorAfter: ""),
                    audioPath: nil, audioStatus: "not_recorded", transcriptionStatus: "pending",
                    transcript: LibraryFixture.prose(bytes: 300, random: &random), cleanedTranscript: nil, displayText: nil, status: "active"))
                try store.saveTurn(ConversationTurn(
                    id: "\(sessionId)-turn-\(index)", sessionId: sessionId, role: "assistant", turnType: "assistant_response", status: "complete",
                    summary: nil, text: LibraryFixture.prose(bytes: 2_000, random: &random), rawText: nil, chapters: nil, sourceInterjectionIds: []))
            }
        }
    }

    private func makeEngine(sessionId: String?, playing: Bool = false) throws -> (engine: SessionEngine, audio: CostAudioClient, store: SQLiteSessionStore) {
        let store = try fixture.openStore(meter: meter)
        let audio = CostAudioClient()
        let engine = SessionEngine(profile: Self.profile(), repository: store, audio: audio, playbackStartTimeout: 5)
        if let sessionId {
            _ = try engine.inspectSession(sessionId: sessionId)
            if playing {
                _ = try engine.resumePlayback()
                audio.startStatus = .confirmed
                _ = try engine.syncPlaybackProgress()
            }
            // The first read of the item's timeline has happened by the time a real completion arrives.
            _ = try engine.syncPlaybackProgress()
        }
        return (engine, audio, store)
    }

    private func measure<State>(_ name: String, setup: () throws -> State, _ call: (State) throws -> Void) throws {
        var times: [Double] = []
        var last: [StoreReadSample] = []
        for _ in 0..<runs {
            let state = try setup()
            meter.reset()
            let clock = ContinuousClock()
            let started = clock.now
            try call(state)
            let elapsed = clock.now - started
            let parts = elapsed.components
            times.append(Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
            last = meter.samples
        }
        // The first run warms SQLite's page cache: it is kept out of the median, but not out of the worst.
        let sorted = times.dropFirst().sorted()
        var perMethod: [String: (calls: Int, bytes: Int)] = [:]
        for sample in last { perMethod[sample.method, default: (0, 0)].calls += 1; perMethod[sample.method, default: (0, 0)].bytes += sample.bytes }
        let reads = perMethod.sorted { $0.value.bytes > $1.value.bytes }.prefix(4)
            .map { "\($0.key) x\($0.value.calls) \($0.value.bytes / 1024) KB" }.joined(separator: "; ")
        rows.append(Row(name: name, ms: sorted[sorted.count / 2], worstMs: times.max() ?? 0,
                        rows: last.map(\.rows).reduce(0, +), bytes: last.map(\.bytes).reduce(0, +), reads: reads))
    }

    func measureEveryCall() throws {
        let mappedTimeline = Self.timeline(durationMs: LibraryFixture.mappedDurationMs)
        let longTimeline = Self.timeline(durationMs: Self.longDurationMs)
        let store = try fixture.openStore()
        let articleText = try store.loadItem(id: articleItemId).text ?? ""
        let bookText = try store.loadItem(id: bookItemId).text ?? ""
        let longId = Self.longItemId, mappedId = LibraryFixture.mappedItemId, articleId = articleItemId, bookId = bookItemId

        // 1. attachTranscriptTimeline
        try measure("attachTranscriptTimeline, 77 min, listening to it", setup: { try makeEngine(sessionId: "session-0", playing: true) }) {
            _ = try $0.engine.attachTranscriptTimeline(itemId: mappedId, timeline: mappedTimeline)
        }
        try measure("attachTranscriptTimeline, 3 h, listening to it", setup: { try makeEngine(sessionId: Self.longSessionId, playing: true) }) {
            _ = try $0.engine.attachTranscriptTimeline(itemId: longId, timeline: longTimeline)
        }
        try measure("attachTranscriptTimeline, 3 h, listening to another item", setup: { try makeEngine(sessionId: Self.articleSessionId, playing: true) }) {
            _ = try $0.engine.attachTranscriptTimeline(itemId: longId, timeline: longTimeline)
        }

        // 2. attachPreparedTextAudio
        let preparedArticle = Self.prepared(text: articleText)
        let preparedBook = Self.prepared(text: bookText)
        try measure("attachPreparedTextAudio, \(articleText.utf8.count / 1024) KB article, listening to it", setup: { try makeEngine(sessionId: Self.articleSessionId, playing: true) }) {
            _ = try $0.engine.attachPreparedTextAudio(itemId: articleId, prepared: preparedArticle)
        }
        try measure("attachPreparedTextAudio, \(bookText.utf8.count / 1024) KB book, listening to it", setup: { try makeEngine(sessionId: Self.bookSessionId, playing: true) }) {
            _ = try $0.engine.attachPreparedTextAudio(itemId: bookId, prepared: preparedBook)
        }
        try measure("attachPreparedTextAudio, \(bookText.utf8.count / 1024) KB book, listening to another item", setup: { try makeEngine(sessionId: "session-0", playing: true) }) {
            _ = try $0.engine.attachPreparedTextAudio(itemId: bookId, prepared: preparedBook)
        }

        // 3. The reply and summary callbacks, in a session with 20 replies and 20 Margins, on the largest book.
        try measure("finishStreamingTurnPlayback, 20 replies", setup: { () -> (SessionEngine, String) in
            let made = try makeEngine(sessionId: Self.bookSessionId, playing: true)
            let turnId = "\(Self.bookSessionId)-turn-3"
            _ = try made.engine.activateStreamingTurn(turnId: turnId)
            return (made.engine, turnId)
        }) { _ = try $0.0.finishStreamingTurnPlayback(turnId: $0.1) }
        try measure("aiProviderFailed, 20 replies", setup: { () -> SessionEngine in
            let made = try makeEngine(sessionId: Self.bookSessionId, playing: true)
            try made.store.saveAIJob(AIJob(id: Self.summaryJobId, kind: "interjection_summary", itemId: bookId, sessionId: Self.bookSessionId,
                                           turnId: "\(Self.bookSessionId)-turn-3", providerType: "local", model: "on-device", status: "pending",
                                           attempts: 0, lastError: nil, messages: [], playbackMode: nil))
            return made.engine
        }) { _ = try $0.aiProviderFailed(error: "offline", sessionId: Self.bookSessionId, turnId: "\(Self.bookSessionId)-turn-3") }
        let margins = (0..<20).map { "\(Self.bookSessionId)-margin-\($0)" }
        let summaryText = String(repeating: "A sentence of the summary. ", count: 80)
        try measure("completeLocalSummary, on a book, 20 Margins", setup: { () -> (SessionEngine, LocalSummaryRequestOrigin) in
            let made = try makeEngine(sessionId: Self.bookSessionId, playing: true)
            try made.store.saveTurn(ConversationTurn(id: Self.summaryTurnId, sessionId: Self.bookSessionId, role: "assistant", turnType: "interjection_summary",
                                                     status: "pending", summary: nil, text: nil, rawText: nil, chapters: nil, sourceInterjectionIds: margins))
            try made.store.saveAIJob(AIJob(id: Self.summaryJobId, kind: "interjection_summary", itemId: bookId, sessionId: Self.bookSessionId,
                                           turnId: Self.summaryTurnId, providerType: "local", model: "on-device", status: "pending",
                                           attempts: 0, lastError: nil, messages: [], playbackMode: nil))
            return (made.engine, try made.engine.localSummaryRequestOrigin(itemId: bookId, turnId: Self.summaryTurnId))
        }) { _ = try $0.0.completeLocalSummary(origin: $0.1, content: summaryText) }

        // 4. updatePlaybackTransport
        let localURL = "file:///PodcastAudio/mapped.mp3"
        try measure("updatePlaybackTransport, at engine install, no session", setup: { try makeEngine(sessionId: nil) }) {
            _ = try $0.engine.updatePlaybackTransport(itemId: mappedId, playbackURL: localURL)
        }
        try measure("updatePlaybackTransport, download finished, keeps the edition", setup: { try makeEngine(sessionId: "session-0", playing: true) }) {
            _ = try $0.engine.updatePlaybackTransport(itemId: mappedId, playbackURL: localURL, replaceActivePlayback: false)
        }
        try measure("updatePlaybackTransport, Download Again, playing, 77 min", setup: { try makeEngine(sessionId: "session-0", playing: true) }) {
            _ = try $0.engine.updatePlaybackTransport(itemId: mappedId, playbackURL: localURL, replaceActivePlayback: true)
        }
        try measure("updatePlaybackTransport, Download Again, playing, 3 h", setup: { try makeEngine(sessionId: Self.longSessionId, playing: true) }) {
            _ = try $0.engine.updatePlaybackTransport(itemId: longId, playbackURL: localURL, replaceActivePlayback: true)
        }

        // 5. transcriptionRetryFailed
        let marginId = "\(Self.bookSessionId)-margin-1"
        try measure("transcriptionRetryFailed, 20 Margins", setup: { () -> SessionEngine in
            let made = try makeEngine(sessionId: Self.bookSessionId, playing: true)
            try made.engine.updateInterjection(marginId, sessionId: Self.bookSessionId) { $0.transcriptionStatus = "pending" }
            return made.engine
        }) { _ = try $0.transcriptionRetryFailed(interjectionId: marginId, sessionId: Self.bookSessionId, error: "offline") }

        // 6. generateListeningMap (the listener's tap)
        var run = 0
        for (label, text) in [("\(articleText.utf8.count / 1024) KB article", articleText), ("\(bookText.utf8.count / 1024) KB book", bookText)] {
            try measure("generateListeningMap, \(label), no map yet", setup: { () -> (SessionEngine, String) in
                run += 1
                let store = try fixture.openStore()
                let id = "gen-\(run)"
                try store.saveItem(Item(id: id, title: "Generated", mediaType: "text", text: text, externalReference: nil, status: "needs_listening_map"))
                try store.saveSession(Session(id: "session-\(id)", itemId: id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
                                              currentTargetId: id, position: Position(charOffset: 100), completionPercent: 1, playbackRate: 1))
                return (try makeEngine(sessionId: "session-\(id)").engine, id)
            }) { _ = try $0.0.generateListeningMap(itemId: $0.1) }
        }
    }

    func markdown() -> String {
        var lines = ["| call | median ms | worst ms | rows | read bytes | largest reads |", "|---|---:|---:|---:|---:|---|"]
        for row in rows {
            lines.append("| \(row.name) | \(String(format: "%.2f", row.ms)) | \(String(format: "%.2f", row.worstMs)) | \(row.rows) | \(ByteCountFormatter.string(fromByteCount: Int64(row.bytes), countStyle: .file)) | \(row.reads) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A player that reports a steady place and does no work, so the numbers are the engine's and the store's.
final class CostAudioClient: AudioPlaybackClient {
    var startStatus: PlaybackStartStatus = .pending
    var activeTargetId: String?
    var mediaTimeMs: Int?
    var charOffset: Int?

    func configureMediaContext(_ context: PlaybackMediaContext?) throws {}
    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {}
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { activeTargetId = targetId }
    func play(targetId: String, from charOffset: Int) throws { activeTargetId = targetId; self.charOffset = charOffset }
    func play(targetId: String, seekingTo charOffset: Int) throws { activeTargetId = targetId; self.charOffset = charOffset }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws { activeTargetId = targetId; self.mediaTimeMs = mediaTimeMs }
    func seek(toMediaTimeMs mediaTimeMs: Int) throws { self.mediaTimeMs = mediaTimeMs }
    func pause() throws {}
    func currentPlaybackPosition() -> PlaybackPosition? {
        mediaTimeMs.map { PlaybackPosition(targetId: activeTargetId, mediaTimeMs: $0, durationMs: 3_600_000, playbackRate: 1, anchorConfidence: .mediaTime) }
    }
    func isPlaybackComplete(targetId: String) -> Bool { false }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { startStatus }
}
