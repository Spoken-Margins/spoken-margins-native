import XCTest
@testable import SessionKit

/// #2256: playing a text item projected all of its text on the main thread (282 ms for a long article). The projection
/// is now made off the main thread when the item is opened, and the play finds it ready.
final class PlaybackProjectionPrewarmTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"], "timeline": ["chapter_timing"]]
    )

    /// An article long enough for the memo, with markup and links so the projection actually changes it.
    private func longArticle(paragraphs: Int = 250) -> String {
        (0..<paragraphs).map {
            "Paragraph \($0) opens <b>here</b> and cites https://example.com/a/\($0) before it ends, with more words to read aloud."
        }.joined(separator: "\n\n")
    }

    /// Speaks what it is given and records what the engine asked it to prepare.
    private final class RecordingSpeech: AudioPlaybackClient {
        var prepared: [String] = []
        func prepareSpeechText(_ text: String) throws -> String {
            prepared.append(text)
            return SpeechTextNormalizer.normalizeWithSourceOffsets(text).text
        }
        func play(targetId: String) throws {}
        func play(targetId: String, from charOffset: Int) throws {}
        func pause() throws {}
    }

    override func setUp() { SpeechTextNormalizer.projectionMemo.forget() }
    override func tearDown() { SpeechTextNormalizer.projectionMemo.forget() }

    func testAPrewarmedTextIsServedWithoutProjectingAgain() {
        let text = longArticle()
        XCTAssertGreaterThan(text.utf8.count, SpeechProjectionMemo.minimumBytes)
        XCTAssertFalse(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .speech))

        SpeechTextNormalizer.prewarm(text)
        XCTAssertTrue(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .speech))

        var computes = 0
        let served = SpeechTextNormalizer.projectionMemo.projection(of: text, kind: .speech) {
            computes += 1
            return NormalizedSpeechText(text: "WRONG", sourceOffsets: [], sourceLength: 0)
        }
        XCTAssertEqual(computes, 0, "a play after a prewarm must not project the text again")
        XCTAssertEqual(served, SpeechTextNormalizer.normalizeWithSourceOffsets(text))
        XCTAssertFalse(served.text.contains("<b>"), "the memo holds the real projection, with the markup gone")
    }

    func testAChangedTextIsNeverServedTheOldProjection() {
        let text = longArticle()
        SpeechTextNormalizer.prewarm(text)
        // Same length, one character different, at the end where a length or prefix check would miss it.
        let changed = String(text.dropLast()) + "!"
        XCTAssertEqual(text.count, changed.count)
        XCTAssertFalse(SpeechTextNormalizer.projectionMemo.remembers(changed, kind: .speech))
        XCTAssertTrue(SpeechTextNormalizer.normalizeWithSourceOffsets(changed).text.hasSuffix("!"))
        XCTAssertTrue(SpeechTextNormalizer.projectionMemo.remembers(changed, kind: .speech))
        XCTAssertTrue(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .speech), "the earlier text is still kept: a play's text must survive a render's")
    }

    func testTheOldestTextLeavesWhenMoreThanTheSlotsAreUsed() {
        let memo = SpeechProjectionMemo()
        let projection = NormalizedSpeechText(text: "x", sourceOffsets: [0], sourceLength: 1)
        let texts = (0...SpeechProjectionMemo.slotsPerKind).map { String(repeating: "\($0)", count: 25_000) }
        for text in texts { _ = memo.projection(of: text, kind: .speech) { projection } }
        XCTAssertFalse(memo.remembers(texts[0], kind: .speech))
        for text in texts.dropFirst() { XCTAssertTrue(memo.remembers(text, kind: .speech)) }
    }

    /// Swift's == treats a precomposed letter and its decomposed form as the same string; the speech is not the same.
    func testATextThatOnlyDiffersInUnicodeFormIsNotServedTheOtherFormsProjection() {
        let composed = String(repeating: "caf\u{E9} au lait, ", count: 1_500)
        let decomposed = String(repeating: "cafe\u{301} au lait, ", count: 1_500)
        XCTAssertEqual(composed, decomposed) // the trap
        let memo = SpeechProjectionMemo()
        let projection = NormalizedSpeechText(text: "x", sourceOffsets: [0], sourceLength: 1)
        _ = memo.projection(of: composed, kind: .speech) { projection }
        XCTAssertTrue(memo.remembers(composed, kind: .speech))
        XCTAssertFalse(memo.remembers(decomposed, kind: .speech))
    }

    func testEachVoiceKindKeepsItsOwnProjection() {
        let text = longArticle()
        SpeechTextNormalizer.prewarm(text, kinds: .system)
        XCTAssertTrue(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .systemSpeech))
        XCTAssertFalse(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .speech))
        SpeechTextNormalizer.prewarm(text)
        XCTAssertTrue(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .systemSpeech))
        XCTAssertTrue(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .speech))
    }

    /// An on-device voice hands over to the system voice mid-play (Low Power Mode, no model, a render failure), and
    /// the system voice projects the text its own way: a prewarm for the on-device kind alone left that play to
    /// project 282 ms of text on the main thread.
    func testAnOnDeviceSelectionAlsoProjectsForTheSystemVoiceItMayFallBackTo() {
        let text = longArticle()
        let item = Item(id: "item-fallback", title: "Fallback", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        ItemPlaybackText.prewarmProjection(
            itemId: item.id, repository: repo, kinds: .forSelection(onDeviceVoice: true)
        )
        XCTAssertTrue(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .speech))
        XCTAssertTrue(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .systemSpeech))
    }

    func testASystemVoiceSelectionProjectsOnlyForTheSystemVoice() {
        let text = longArticle()
        let item = Item(id: "item-system", title: "System", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        ItemPlaybackText.prewarmProjection(
            itemId: item.id, repository: repo, kinds: .forSelection(onDeviceVoice: false)
        )
        XCTAssertTrue(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .systemSpeech))
        XCTAssertFalse(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .speech), "no hand-over goes that way")
    }

    func testShortAndHugeTextsAreNotKept() {
        let memo = SpeechProjectionMemo()
        var computes = 0
        let projection = NormalizedSpeechText(text: "x", sourceOffsets: [0], sourceLength: 1)
        for text in ["A short streamed chunk.", String(repeating: "a", count: SpeechProjectionMemo.maximumBytes + 1)] {
            _ = memo.projection(of: text, kind: .speech) { computes += 1; return projection }
            _ = memo.projection(of: text, kind: .speech) { computes += 1; return projection }
            XCTAssertFalse(memo.remembers(text, kind: .speech))
        }
        XCTAssertEqual(computes, 4)
        SpeechTextNormalizer.prewarm("A short streamed chunk.")
        XCTAssertFalse(SpeechTextNormalizer.projectionMemo.remembers("A short streamed chunk.", kind: .speech))
    }

    /// The prewarm only helps if it projects the text the engine speaks, preface included.
    func testThePrewarmProjectsExactlyWhatAPlayThenSpeaks() throws {
        let text = longArticle()
        let item = Item(id: "item-long", title: "A long article", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let map = ListeningMap(id: "map-long", itemId: item.id, overview: "This article repeats one paragraph shape many times.", chapters: [
            Chapter(id: "ch-1", title: "All of it", startChar: 0, endChar: 40, percent: 0)
        ])
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])

        ItemPlaybackText.prewarmProjection(itemId: item.id, repository: repo, kinds: .onDevice)
        let spoken = ItemPlaybackText.text(item: item, map: map, listenable: nil)
        XCTAssertTrue(SpeechTextNormalizer.projectionMemo.remembers(spoken, kind: .speech))

        let audio = RecordingSpeech()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)
        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(audio.prepared, [spoken], "the play asked the player to prepare the text that was prewarmed")
        XCTAssertTrue(spoken.hasPrefix("Overview."), "the preface is part of what is spoken")
    }

    func testAnItemWithoutMapPrewarmsItsPlainText() {
        let text = longArticle()
        let item = Item(id: "item-plain", title: "Plain", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        ItemPlaybackText.prewarmProjection(itemId: item.id, repository: repo, kinds: .onDevice)
        XCTAssertTrue(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .speech))
    }

    func testAnItemThatPlaysARecordingOrHasNoTextPrewarmsNothing() {
        let recording = Item(
            id: "item-podcast", title: "Episode", mediaType: "transcript_backed_media", text: longArticle(),
            externalReference: nil, status: "ready"
        )
        let empty = Item(id: "item-empty", title: "Empty", mediaType: "text", text: nil, externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [recording.id: recording, empty.id: empty])
        for id in [recording.id, empty.id, "item-missing"] {
            ItemPlaybackText.prewarmProjection(itemId: id, repository: repo, kinds: .onDevice)
        }
        XCTAssertFalse(SpeechTextNormalizer.projectionMemo.remembers(longArticle(), kind: .speech))
    }
}
