import Foundation
@testable import SessionKit
@testable import SessionKitPersistence

/// A generated Library shaped like the owner's (diagnostics, 2026-10-20), written to a real temporary SQLite file (#2258).
/// Everything is derived from a seed: nothing binary is committed, and two builds with the same scale give the same rows.
///
/// The owner's Library: 319 items, 361 sessions, 36 notes, 26 followed sources with 407 entries, and one mapped
/// podcast of about 77 minutes with two saved transcript versions, Margins and a Listening Map. Article sizes are
/// unknown, so they are spread: mostly 20 to 60 KB, a few books at 1 MB or more.
struct LibraryFixture {
    struct Scale {
        var name: String
        var items: Int
        var sessions: Int
        var notes: Int
        var sources: Int
        var entries: Int
        var books: Int

        /// A tenth of the Library. Quick enough for every default test run.
        static let small = Scale(name: "small", items: 32, sessions: 36, notes: 4, sources: 3, entries: 41, books: 1)
        /// The owner's Library.
        static let library = Scale(name: "library", items: 319, sessions: 361, notes: 36, sources: 26, entries: 407, books: 4)
        /// Three Libraries' worth, to show how each read grows.
        static let triple = Scale(name: "3x", items: 957, sessions: 1083, notes: 108, sources: 78, entries: 1221, books: 12)
    }

    /// The mapped podcast: its id, so a test can open it as the app would.
    static let mappedItemId = "item-mapped-podcast"
    /// 77 minutes, one transcript segment about every 4 seconds.
    static let mappedDurationMs = 77 * 60 * 1000
    static let mappedSegmentMs = 4_000
    static let mappedTimelineVersions = 2
    static let mappedSceneCount = 14
    static let mappedMarginCount = 18

    let scale: Scale
    let directory: URL
    var databaseURL: URL { directory.appendingPathComponent("library.sqlite") }
    /// Total UTF-8 bytes of article and book text written, for the table.
    private(set) var textBytes = 0
    private(set) var itemIds: [String] = []
    /// The first article (an item with text), for reads that take one item.
    var articleItemId: String { itemIds[max(1, scale.items / 12)] }

    static func build(_ scale: Scale, seed: UInt64 = 2258) throws -> LibraryFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-fixture-\(scale.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var fixture = LibraryFixture(scale: scale, directory: directory)
        try fixture.write(seed: seed)
        return fixture
    }

    /// A store on the fixture's file. Pass a meter to count its reads; the build's own writes are never counted.
    func openStore(meter: StoreReadMeter? = nil) throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: databaseURL.path, readMeter: meter)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private init(scale: Scale, directory: URL) {
        self.scale = scale
        self.directory = directory
    }

    // MARK: Writing

    private mutating func write(seed: UInt64) throws {
        var random = SplitMix64(seed: seed)
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let epoch = Date(timeIntervalSince1970: 1_760_000_000)

        // Feeds first: followed sources, then their entries (half carry the full article body).
        for index in 0..<scale.sources {
            let kind: SourceIdentityKind = index % 3 == 0 ? .podcastFeed : .articleFeed
            try store.saveFeedSubscription(FeedSubscription(
                id: "feed-\(index)",
                source: SourceIdentity(id: "source-\(index)", kind: kind, canonicalURL: "https://example.com/feed-\(index)",
                                       host: "example.com", title: "Source \(index)"),
                createdAt: epoch))
        }
        for index in 0..<scale.entries {
            let hasBody = index % 2 == 0
            let body = hasBody ? Self.prose(bytes: 5_000 + Int(random.next() % 25_000), random: &random) : nil
            try store.saveFeedEntry(FeedEntry(
                id: "entry-\(index)", subscriptionId: "feed-\(index % scale.sources)",
                canonicalURL: "https://example.com/feed-\(index % scale.sources)/post-\(index)", title: "Entry \(index)",
                summary: Self.prose(bytes: 500, random: &random),
                publishedAt: epoch.addingTimeInterval(Double(index) * 3_600),
                state: index % 5 == 0 ? .imported : .unseen, bodyWordCount: body.map { $0.split(separator: " ").count },
                fullBody: body))
        }

        // Items: the mapped podcast, other podcast episodes, then articles with a spread of sizes and a few books.
        let podcasts = max(1, scale.items / 12)
        for index in 0..<scale.items {
            let isMapped = index == 0
            let id = isMapped ? Self.mappedItemId : "item-\(index)"
            itemIds.append(id)
            let isPodcast = index < podcasts
            var text: String?
            if !isPodcast {
                let isBook = index >= scale.items - scale.books
                let size = isBook ? 1_000_000 + Int(random.next() % 600_000) : 20_000 + Int(random.next() % 40_000)
                text = Self.prose(bytes: size, random: &random)
                textBytes += size
            }
            try store.saveItem(Item(
                id: id, title: isMapped ? "Mapped podcast, 77 minutes" : "Item \(index)",
                mediaType: isPodcast ? "audio" : "text", text: text, externalReference: "https://example.com/item-\(index)",
                status: "Ready", createdAt: epoch.addingTimeInterval(Double(index) * 600)))
            if isPodcast {
                try store.saveAudioAsset(AudioAsset(
                    id: "asset-\(id)", itemId: id, audioSourceType: .nativeMediaFile, availability: .localPhone,
                    filePath: "Podcasts/\(id).mp3", durationMs: isMapped ? Self.mappedDurationMs : 3_000_000,
                    codec: "mp3", title: "Item \(index)", createdAt: epoch))
            }
        }

        // Sessions: the mapped item gets one; the rest are spread over the other items, several items twice.
        for index in 0..<scale.sessions {
            let itemId = index == 0 ? Self.mappedItemId : itemIds[(index * 7) % itemIds.count]
            let id = "session-\(index)"
            let created = epoch.addingTimeInterval(Double(index) * 900)
            try store.saveSession(Session(
                id: id, itemId: itemId, createdAt: created, updatedAt: created,
                status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: itemId,
                position: Position(charOffset: Int(random.next() % 20_000)), completionPercent: Int(random.next() % 100), playbackRate: 1))
            try store.saveTurn(ConversationTurn(
                id: "turn-\(id)", sessionId: id, role: "assistant", turnType: "assistant_response", status: "complete",
                summary: nil, text: Self.prose(bytes: 600, random: &random), rawText: nil, chapters: nil, sourceInterjectionIds: []))
            if index >= 1, index <= scale.notes {
                try store.saveInterjection(Self.margin("note-\(index)", session: id, item: itemId, at: created, random: &random))
            }
        }

        try writeMappedPodcast(store, epoch: epoch, random: &random)
    }

    /// The mapped podcast: a full transcript saved twice, scenes as a Listening Map, Margins, and summary bridge assets.
    private func writeMappedPodcast(_ store: SQLiteSessionStore, epoch: Date, random: inout SplitMix64) throws {
        let id = Self.mappedItemId
        let segmentCount = Self.mappedDurationMs / Self.mappedSegmentMs
        var segments: [MediaTimelineSegment] = []
        segments.reserveCapacity(segmentCount)
        var offset = 0
        for index in 0..<segmentCount {
            let text = Self.prose(bytes: 220, random: &random)
            let length = text.utf8.count
            segments.append(MediaTimelineSegment(
                id: "seg-\(index)", startMs: index * Self.mappedSegmentMs, endMs: (index + 1) * Self.mappedSegmentMs,
                startChar: offset, endChar: offset + length, text: text,
                sourceLocator: SourceLocator(documentId: id, segmentId: "seg-\(index)", utf8Start: offset, utf8End: offset + length)))
            offset += length + 1
        }
        let sceneMs = Self.mappedDurationMs / Self.mappedSceneCount
        let chapters = (0..<Self.mappedSceneCount).map {
            MediaTimelineChapter(id: "ch-\($0)", title: "Scene \($0)", description: Self.prose(bytes: 300, random: &random),
                                 startMs: $0 * sceneMs, transcriptSegmentId: "seg-\($0 * sceneMs / Self.mappedSegmentMs)")
        }
        for version in 0..<Self.mappedTimelineVersions {
            try store.saveTranscriptTimeline(SourceTranscriptTimeline(
                id: "timeline-\(version)", itemId: id, createdAt: epoch.addingTimeInterval(Double(version) * 60),
                timeline: MediaTimeline(segments: segments, chapters: chapters, durationMs: Self.mappedDurationMs)))
        }
        try store.saveListeningMap(ListeningMap(
            id: "map-\(id)", itemId: id, overview: Self.prose(bytes: 1_200, random: &random),
            chapters: (0..<Self.mappedSceneCount).map {
                Chapter(id: "map-ch-\($0)", title: "Scene \($0)", startChar: $0 * 1_000, endChar: ($0 + 1) * 1_000,
                        percent: $0 * 100 / Self.mappedSceneCount)
            }))
        // Summary bridge audio, one per scene, beside the episode itself: the asset table grows with the map.
        for scene in 0..<Self.mappedSceneCount {
            try store.saveAudioAsset(AudioAsset(
                id: "bridge-\(scene)", itemId: id, audioSourceType: .generatedTTSPrerendered, availability: .localPhone,
                filePath: "Bridges/\(scene).m4a", durationMs: 20_000, codec: "aac", voiceId: "kitten", title: "Scene \(scene) bridge",
                createdAt: epoch))
        }
        for index in 0..<Self.mappedMarginCount {
            try store.saveInterjection(Self.margin("mapped-margin-\(index)", session: "session-0", item: id,
                                                   at: epoch.addingTimeInterval(Double(index)), random: &random,
                                                   mediaTimeMs: index * (Self.mappedDurationMs / Self.mappedMarginCount)))
        }
    }

    private static func margin(_ id: String, session: String, item: String, at date: Date, random: inout SplitMix64,
                               mediaTimeMs: Int? = nil) -> Interjection {
        let anchor = Anchor(anchorType: mediaTimeMs == nil ? .text : .media, startChar: 0, endChar: 12,
                            anchorBefore: "", anchorAfter: "", mediaTimeMs: mediaTimeMs)
        return Interjection(
            id: id, itemId: item, sessionId: session, targetType: .item, targetId: item, createdAt: date, roughPercent: 0,
            anchor: anchor, audioPath: nil, audioStatus: "not_recorded", transcriptionStatus: "transcribed",
            transcript: prose(bytes: 200, random: &random), cleanedTranscript: nil, displayText: nil, status: "active")
    }

    // MARK: Text

    private static let words = [
        "listening", "margin", "episode", "the", "of", "and", "a", "to", "in", "that", "was", "it", "for", "on", "with",
        "chapter", "story", "voice", "reading", "article", "interview", "scene", "notes", "which", "about", "their",
        "because", "between", "remember", "another", "program", "sentence", "paragraph", "returned", "quietly"
    ]

    /// Sentence-shaped text of about `bytes` UTF-8 bytes (all ASCII, so characters equal bytes).
    static func prose(bytes: Int, random: inout SplitMix64) -> String {
        var out = String()
        out.reserveCapacity(bytes + 16)
        var sentenceLength = 0
        while out.utf8.count < bytes {
            out += words[Int(random.next() % UInt64(words.count))]
            sentenceLength += 1
            if sentenceLength >= 12 + Int(random.next() % 8) {
                out += ". "
                sentenceLength = 0
            } else {
                out += " "
            }
        }
        return String(out.prefix(bytes))
    }
}

/// A small seeded generator, so the same seed gives the same Library on every machine and run.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
