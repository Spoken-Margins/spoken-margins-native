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

    /// A book too big for the memo to hold twice keeps the chosen voice's projection, not the fallback's pushing it out.
    /// (Projecting a real 3 MB book takes tens of seconds, so the budget rule is tested directly.)
    func testABookTooBigToKeepTwiceIsOnlyProjectedForTheFirstKind() {
        let article = longArticle().utf8.count
        XCTAssertTrue(SpeechProjectionMemo.fits(utf8Count: article, copies: 2), "a long article is kept for both players")
        let book = 3_500_000
        XCTAssertTrue(SpeechProjectionMemo.holds(utf8Count: book))
        XCTAssertTrue(SpeechProjectionMemo.fits(utf8Count: book, copies: 1))
        XCTAssertFalse(SpeechProjectionMemo.fits(utf8Count: book, copies: 2), "the second copy would push the first out")
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
            XCTAssertNil(ItemPlaybackText.prewarmProjection(itemId: id, repository: repo, kinds: .onDevice))
        }
        XCTAssertFalse(SpeechTextNormalizer.projectionMemo.remembers(longArticle(), kind: .speech))
    }

    // MARK: A PDF's listenable text (#2256)

    /// A PDF whose page header and table are not read, so its listenable text differs from `Item.text`.
    private func pdfFixture(id: String = "item-pdf", body: String = "Levels rose as expected in every cohort we followed.") -> (item: Item, document: StructuredDocument) {
        let document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0),
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: body, role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "Participant Sessions P1 14", role: .table, pageIndex: 0),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 1)
        let item = Item(id: id, title: "A paper", mediaType: "pdf", text: document.text, externalReference: nil, status: "ready")
        return (item, document)
    }

    /// The listener opens the PDF (the prewarm reads its document off main), and the play that follows never reads the
    /// document: it is deleted from the store between the two, so only the kept projection can supply the text.
    func testAPlayOfAPrewarmedPDFSpeaksItsListenableTextWithoutReadingTheDocument() throws {
        let (item, document) = pdfFixture()
        let listenable = StructuredDocumentSpeech.listenableText(document).text
        XCTAssertNotEqual(listenable, item.text, "the fixture must tell the listenable text from Item.text")
        let repo = InMemorySessionRepository(items: [item.id: item])
        try repo.saveStructuredDocument(document, itemId: item.id)
        let audio = RecordingSpeech()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        let generation = engine.listenableProjectionGeneration
        let prewarmed = try XCTUnwrap(ItemPlaybackText.prewarmProjection(itemId: item.id, repository: repo, kinds: .onDevice))
        XCTAssertEqual(prewarmed.projection?.text, listenable)
        engine.adoptPrewarmedListenableProjection(prewarmed, generation: generation)
        repo.structuredDocuments = [:]

        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(audio.prepared, [listenable], "the play used the prewarmed projection, not a document read")
    }

    /// The control for the test above: with nothing kept and the document gone, the play speaks `Item.text`, so the
    /// test above can only pass through the kept projection.
    func testWithoutAKeptProjectionAndNoDocumentThePlaySpeaksTheItemText() throws {
        let (item, document) = pdfFixture()
        let repo = InMemorySessionRepository(items: [item.id: item])
        try repo.saveStructuredDocument(document, itemId: item.id)
        let audio = RecordingSpeech()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)
        repo.structuredDocuments = [:]
        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(audio.prepared, [item.text])
    }

    /// A document saved after the prewarm began (a re-import, an upgrade) may differ from the one it read.
    func testAProjectionReadBeforeADocumentWasSavedIsDropped() throws {
        let (item, document) = pdfFixture()
        let repo = InMemorySessionRepository(items: [item.id: item])
        try repo.saveStructuredDocument(document, itemId: item.id)
        let audio = RecordingSpeech()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        let generation = engine.listenableProjectionGeneration
        let prewarmed = try XCTUnwrap(ItemPlaybackText.prewarmProjection(itemId: item.id, repository: repo, kinds: .onDevice))
        // The same text, read differently: its body is now a reference, which is announced, not read.
        let reread = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0),
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "Levels rose as expected in every cohort we followed.", role: .reference, pageIndex: 0),
            StructuredDocumentLine(text: "Participant Sessions P1 14", role: .table, pageIndex: 0),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 1)
        XCTAssertEqual(reread.text, document.text)
        try repo.saveStructuredDocument(reread, itemId: item.id)
        engine.forgetDocumentCaches(itemId: item.id) // what every save through the engine does

        engine.adoptPrewarmedListenableProjection(prewarmed, generation: generation)
        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(audio.prepared, [StructuredDocumentSpeech.listenableText(reread).text])
        XCTAssertNotEqual(audio.prepared, [prewarmed.projection?.text ?? ""])
    }

    /// The projection comes back after the save, but was read before it: the generation is what tells them apart.
    func testAProjectionKeptThenOvertakenBySaveIsForgotten() throws {
        let (item, document) = pdfFixture()
        let repo = InMemorySessionRepository(items: [item.id: item])
        try repo.saveStructuredDocument(document, itemId: item.id)
        let audio = RecordingSpeech()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)
        let generation = engine.listenableProjectionGeneration
        let prewarmed = try XCTUnwrap(ItemPlaybackText.prewarmProjection(itemId: item.id, repository: repo, kinds: .onDevice))
        engine.adoptPrewarmedListenableProjection(prewarmed, generation: generation)
        engine.forgetDocumentCaches(itemId: item.id)
        repo.structuredDocuments = [:]
        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(audio.prepared, [item.text], "the kept projection was dropped with the save; the play found no document")
    }

    /// Opening another PDF while one plays must not push the playing one's projection out.
    func testOpeningAnotherPDFDoesNotEvictThePlayingOnesProjection() throws {
        let (playing, playingDocument) = pdfFixture(id: "item-playing")
        let (other, otherDocument) = pdfFixture(id: "item-other", body: "A second paper with different words entirely.")
        let repo = InMemorySessionRepository(items: [playing.id: playing, other.id: other])
        try repo.saveStructuredDocument(playingDocument, itemId: playing.id)
        try repo.saveStructuredDocument(otherDocument, itemId: other.id)
        let audio = RecordingSpeech()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: playing.id) // reads the document once and caches the projection
        let generation = engine.listenableProjectionGeneration
        let prewarmed = try XCTUnwrap(ItemPlaybackText.prewarmProjection(itemId: other.id, repository: repo, kinds: .onDevice))
        engine.adoptPrewarmedListenableProjection(prewarmed, generation: generation)
        repo.structuredDocuments = [:]

        _ = try engine.startSession(itemId: playing.id)
        XCTAssertEqual(audio.prepared.last, StructuredDocumentSpeech.listenableText(playingDocument).text)
    }

    /// A projection for a different text length is not served: the length is the engine's match, as for its own cache.
    func testAProjectionForADifferentTextLengthIsNotServed() throws {
        let (item, document) = pdfFixture()
        let repo = InMemorySessionRepository(items: [item.id: item])
        try repo.saveStructuredDocument(document, itemId: item.id)
        let audio = RecordingSpeech()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)
        let wrong = PrewarmedListenableProjection(
            itemId: item.id, textLength: (item.text ?? "").count + 1,
            projection: NormalizedSpeechText(text: "WRONG", sourceOffsets: [], sourceLength: 0)
        )
        engine.adoptPrewarmedListenableProjection(wrong, generation: engine.listenableProjectionGeneration)
        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(audio.prepared, [StructuredDocumentSpeech.listenableText(document).text])
    }

    /// A PDF the new reader has no document for has "no listenable text", and that answer is kept too.
    func testAPDFWithNoDocumentIsPrewarmedAsHavingNoListenableText() throws {
        let item = Item(id: "item-old-pdf", title: "Old", mediaType: "pdf", text: "Plain words from an older import.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let prewarmed = try XCTUnwrap(ItemPlaybackText.prewarmProjection(itemId: item.id, repository: repo, kinds: .onDevice))
        XCTAssertNil(prewarmed.projection)
        XCTAssertEqual(prewarmed.textLength, item.text?.count)
    }
}
