import XCTest
@testable import SessionKit

/// #336, Codex audit on 2a0d49f: a new-reader PDF's narration chunk can say the end of the body
/// and the start of the appendix in one breath, though the references sit between them in
/// `Item.text`. Its timeline must not point into the references.
final class NarrationTimelinePiecesTests: XCTestCase {
    private let references = (1...40).map { "[\($0)] A. Author. A cited title number \($0). Journal of Examples. 2019." }
    private var document: StructuredDocument {
        StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "Levels rose as expected in every cohort we followed.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2),
        ] + references.map { StructuredDocumentLine(text: $0, role: .reference, pageIndex: 1) } + [
            StructuredDocumentLine(text: "Appendix", role: .heading, pageIndex: 2, level: 2),
            StructuredDocumentLine(text: "Supplementary methods are read aloud.", role: .body, pageIndex: 2),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 3)
    }

    /// The references a listener never hears. "References skipped." is spoken at the first
    /// reference's first character, so the narration may reach that character but no further.
    private func referencesRange(in text: String) throws -> Range<Int> {
        let first = try XCTUnwrap(text.range(of: "[1] A. Author"))
        let last = try XCTUnwrap(text.range(of: "number 40. Journal of Examples. 2019."))
        return (text.distance(from: text.startIndex, to: first.lowerBound) + 1)..<text.distance(from: text.startIndex, to: last.upperBound)
    }

    /// The whole spoken paper as one chunk: the worst case the audit describes.
    private func wholePaperPieces() throws -> (pieces: [NarrationTimelinePiece], itemText: String) {
        let item = Item(id: "item-paper", title: "Paper", mediaType: "pdf", text: document.text, externalReference: nil, status: "ready")
        let speech = try XCTUnwrap(PreparedSpeechText(item: item, document: document))
        XCTAssertFalse(speech.text.contains("A cited title"), "precondition: references aren't spoken")
        let projection = speech.assemblyProjection()
        let pieces = NarrationTimelinePieces.pieces(
            spokenRange: 0..<projection.text.count, startMs: 0, endMs: 10_000,
            projection: projection, source: Array(speech.itemText)
        )
        return (pieces, speech.itemText)
    }

    func testAChunkThatSpeaksAcrossSkippedReferencesIsSplitWhereTheTextJumps() throws {
        let (pieces, itemText) = try wholePaperPieces()
        let skipped = try referencesRange(in: itemText)
        XCTAssertGreaterThan(pieces.count, 1, "the chunk is split")
        XCTAssertEqual(pieces.first?.startMs, 0)
        XCTAssertEqual(pieces.last?.endMs, 10_000)
        for (previous, next) in zip(pieces, pieces.dropFirst()) {
            XCTAssertEqual(previous.endMs, next.startMs, "the pieces cover the chunk's audio without gaps")
            XCTAssertEqual(previous.spokenRange.upperBound, next.spokenRange.lowerBound)
        }
        for piece in pieces {
            XCTAssertLessThan(piece.startMs, piece.endMs)
            XCTAssertFalse(skipped.overlaps(piece.startChar..<piece.endChar),
                           "a piece reads \(piece.startChar)..<\(piece.endChar), inside the references \(skipped)")
        }
    }

    func testPositionsThroughTheChunkNeverLandInTheReferences() throws {
        let (pieces, itemText) = try wholePaperPieces()
        let skipped = try referencesRange(in: itemText)
        let timeline = TranscriptTimeline(
            segments: pieces.enumerated().map { index, piece in
                MediaTimelineSegment(id: "seg-\(index)", startMs: piece.startMs, endMs: piece.endMs,
                                     startChar: piece.startChar, endChar: piece.endChar, text: "")
            },
            chapters: [], durationMs: 10_000
        )
        for time in stride(from: 0, to: 10_000, by: 50) {
            let offset = PreparedNarrationFallback.textOffset(mediaTimeMs: time, timeline: timeline)
            // The place just after the notice is fine: live speech resumes from the next heard word.
            XCTAssertFalse(skipped.dropFirst().contains(offset), "at \(time) ms the narration's place is \(offset), inside the references")
        }
    }

    /// "Its share of the chunk's time is its share of the chunk's spoken characters." The body's stretch is the 92
    /// characters before "Appendix" and the appendix's the 46 after, so the cut is 92/138 of 10 s, not the middle.
    func testTheChunksTimeIsSplitInProportionToEachPiecesSpokenCharacters() throws {
        let (pieces, itemText) = try wholePaperPieces()
        let item = Item(id: "item-paper", title: "Paper", mediaType: "pdf", text: itemText, externalReference: nil, status: "ready")
        let spoken = try XCTUnwrap(PreparedSpeechText(item: item, document: document)).assemblyProjection().text
        let bodyCharacters = spoken.distance(from: spoken.startIndex, to: try XCTUnwrap(spoken.range(of: "Appendix")).lowerBound)
        XCTAssertEqual(bodyCharacters, 92, "precondition: the spoken text the proportions come from")
        XCTAssertEqual(spoken.count, 138, "precondition")
        let boundary = Int((10_000 * Double(bodyCharacters) / Double(spoken.count)).rounded())
        XCTAssertEqual(boundary, 6_667)

        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].spokenRange, 0..<bodyCharacters)
        XCTAssertEqual(pieces[0].endMs, boundary, accuracy: 1, "the body keeps its 92/138 of the time")
        XCTAssertEqual(pieces[1].startMs, pieces[0].endMs)
        XCTAssertEqual(pieces[1].spokenRange, bodyCharacters..<spoken.count)
    }

    /// A Margin made a moment either side of the cut belongs to the passage being spoken at that moment.
    func testAMarginJustEitherSideOfTheCutOpensOnThePassageBeingSpoken() throws {
        let (pieces, itemText) = try wholePaperPieces()
        let skipped = try referencesRange(in: itemText)
        let timeline = TranscriptTimeline(
            segments: pieces.enumerated().map { index, piece in
                MediaTimelineSegment(id: "seg-\(index)", startMs: piece.startMs, endMs: piece.endMs,
                                     startChar: piece.startChar, endChar: piece.endChar, text: "")
            },
            chapters: [], durationMs: 10_000
        )
        let cut = 6_667 // 92 of the 138 spoken characters are the body's
        for early in [cut - 400, cut - 50, cut - 1] {
            let offset = PreparedNarrationFallback.textOffset(mediaTimeMs: early, timeline: timeline)
            XCTAssertLessThanOrEqual(offset, skipped.lowerBound, "at \(early) ms the body is still being read, not the appendix at \(offset)")
        }
        for late in [cut, cut + 50, cut + 400] {
            let offset = PreparedNarrationFallback.textOffset(mediaTimeMs: late, timeline: timeline)
            XCTAssertGreaterThanOrEqual(offset, skipped.upperBound, "at \(late) ms the appendix is being read, not the body at \(offset)")
        }
    }

    // MARK: Hand-made projections

    /// A projection that speaks only the given stretches of `source`, as the normalizer does with text it drops.
    private func makeProjection(of source: String, speaking stretches: [String]) -> (NormalizedSpeechText, [Range<Int>]) {
        let characters = Array(source)
        var text = "", offsets: [Int] = [], ranges: [Range<Int>] = []
        var searchFrom = source.startIndex
        for stretch in stretches {
            let found = source.range(of: stretch, range: searchFrom..<source.endIndex)!
            let lower = source.distance(from: source.startIndex, to: found.lowerBound)
            let upper = source.distance(from: source.startIndex, to: found.upperBound)
            ranges.append(lower..<upper)
            for index in lower..<upper { text.append(characters[index]); offsets.append(index) }
            searchFrom = found.upperBound
        }
        return (NormalizedSpeechText(text: text, sourceOffsets: offsets, sourceLength: characters.count), ranges)
    }

    func testTwoSkippedStretchesMakeThreePiecesWithTheirOwnShareOfTheTime() {
        let source = "First part. HIDDEN one words. Second part here. HIDDEN two words. Third."
        let (projection, stretches) = makeProjection(of: source, speaking: ["First part. ", "Second part here. ", "Third."])
        XCTAssertEqual(projection.text.count, 36, "precondition: 12 + 18 + 6 spoken characters")

        // 3,600 ms for 36 characters is 100 ms each, after a start of 1,000 ms.
        let pieces = NarrationTimelinePieces.pieces(
            spokenRange: 0..<36, startMs: 1_000, endMs: 4_600, projection: projection, source: Array(source)
        )

        XCTAssertEqual(pieces.map(\.spokenRange), [0..<12, 12..<30, 30..<36])
        XCTAssertEqual(pieces.map(\.startMs), [1_000, 2_200, 4_000])
        XCTAssertEqual(pieces.map(\.endMs), [2_200, 4_000, 4_600])
        XCTAssertEqual(pieces.map(\.startChar), stretches.map(\.lowerBound), "each piece starts where its words do")
        XCTAssertEqual(pieces.map(\.endChar), [stretches[0].upperBound, stretches[1].upperBound, source.count],
                       "and stops after its own last word, short of the skipped text")
    }

    func testARunTooShortForItsOwnMillisecondIsReadWithTheNextPiece() {
        let source = "A HIDDEN words " + String(repeating: "B", count: 399)
        let (projection, _) = makeProjection(of: source, speaking: ["A", String(repeating: "B", count: 399)])
        XCTAssertEqual(projection.text.count, 400, "precondition")

        // 1 of 400 characters of 100 ms is a quarter of a millisecond: it rounds to the chunk's own start.
        let pieces = NarrationTimelinePieces.pieces(
            spokenRange: 0..<400, startMs: 0, endMs: 100, projection: projection, source: Array(source)
        )
        XCTAssertEqual(pieces.map(\.spokenRange), [0..<400], "one piece, not an empty one followed by the rest")
        XCTAssertEqual(pieces.map(\.startMs), [0])
        XCTAssertEqual(pieces.map(\.endMs), [100])

        // The same at the other end: the last run is 1 of 400 characters, a quarter of a millisecond before the end.
        let tail = "B" + String(repeating: "B", count: 398) + " HIDDEN words C"
        let (tailProjection, _) = makeProjection(of: tail, speaking: [String(repeating: "B", count: 399), "C"])
        let tailPieces = NarrationTimelinePieces.pieces(
            spokenRange: 0..<400, startMs: 0, endMs: 100, projection: tailProjection, source: Array(tail)
        )
        XCTAssertEqual(tailPieces.map(\.spokenRange), [0..<400])
        XCTAssertEqual(tailPieces.map(\.endMs), [100])
    }

    func testAChunkThatReadsOneStretchOfTextIsOneSegmentAsBefore() {
        let text = "First sentence of the article. Second sentence, with a comma; and more.  Third."
        let projection = SpeechTextNormalizer.normalizeWithSourceOffsets(text)
        let pieces = NarrationTimelinePieces.pieces(
            spokenRange: 0..<31, startMs: 0, endMs: 2_000, projection: projection, source: Array(text)
        )
        XCTAssertEqual(pieces, [NarrationTimelinePiece(
            spokenRange: 0..<31, startMs: 0, endMs: 2_000,
            startChar: projection.sourceOffset(atSpokenCharacterOffset: 0),
            endChar: projection.sourceOffset(atSpokenCharacterOffset: 31)
        )])
    }

    func testAChunkEndingBeforeSkippedReferencesStopsAtItsOwnLastWord() throws {
        let item = Item(id: "item-paper", title: "Paper", mediaType: "pdf", text: document.text, externalReference: nil, status: "ready")
        let speech = try XCTUnwrap(PreparedSpeechText(item: item, document: document))
        let projection = speech.assemblyProjection()
        let skipped = try referencesRange(in: speech.itemText)
        // A chunk that ends where the appendix's chunk begins.
        let appendix = projection.text.distance(from: projection.text.startIndex, to: try XCTUnwrap(projection.text.range(of: "Appendix")).lowerBound)
        let piece = try XCTUnwrap(NarrationTimelinePieces.pieces(
            spokenRange: 0..<appendix, startMs: 0, endMs: 5_000, projection: projection, source: Array(speech.itemText)
        ).last)
        XCTAssertLessThanOrEqual(piece.endChar, skipped.lowerBound, "the body's chunk doesn't reach over the references")
    }

    // The audit's Margin round trip, through SessionEngine: a written Margin made during the body's
    // stretch of a split chunk opens on the body, and one made during the appendix's on the appendix.
    func testAMarginMadeDuringNarrationOpensOnTheWordsBeingSpoken() throws {
        let narrationFile = FileManager.default.temporaryDirectory.appending(path: "narration-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: narrationFile)
        defer { try? FileManager.default.removeItem(at: narrationFile) }
        let (pieces, itemText) = try wholePaperPieces()
        let skipped = try referencesRange(in: itemText)
        let item = Item(id: "item-paper", title: "Paper", mediaType: "pdf", text: itemText, externalReference: nil, status: "ready")
        let prepared = PreparedTextAudio(
            normalizedText: itemText,
            media: ItemMedia(sourceType: .generatedTTSPrerendered, url: narrationFile.absoluteString,
                             durationMs: 10_000, nativeMediaId: narrationFile.absoluteString),
            timeline: TranscriptTimeline(
                segments: pieces.enumerated().map { index, piece in
                    MediaTimelineSegment(id: "seg-\(index)", startMs: piece.startMs, endMs: piece.endMs,
                                         startChar: piece.startChar, endChar: piece.endChar, text: "piece \(index)")
                },
                chapters: [], durationMs: 10_000
            )
        )
        let audio = MediaClockAudioClient()
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: [
                    "sync": ["canonical_persistence"],
                    "playback": ["realtime_tts", "prerendered_audio", "native_media"],
                    "timeline": ["transcript_segments", "media_time", "chapter_timing"],
                ]
            ),
            repository: repository,
            audio: audio
        )
        _ = try engine.attachPreparedTextAudio(itemId: item.id, prepared: prepared)
        let started = try engine.startSession(itemId: item.id)
        XCTAssertEqual(started.targetType, TargetType.transcriptBackedMedia.rawValue, "the narration plays")

        func passage(ofMarginAt mediaTimeMs: Int) throws -> String {
            audio.mediaTimeMs = mediaTimeMs
            let capture = try engine.beginWrittenInterjection()
            _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "A note at \(mediaTimeMs) ms")
            let sessionId = try XCTUnwrap(engine.currentSession?.id)
            let margin = try XCTUnwrap(try repository.loadInterjections(sessionId: sessionId).first { $0.displayText == "A note at \(mediaTimeMs) ms" })
            let start = try XCTUnwrap(margin.anchor.startChar), end = try XCTUnwrap(margin.anchor.endChar)
            XCTAssertFalse(skipped.overlaps(start..<max(start + 1, end)), "the Margin at \(mediaTimeMs) ms opens inside the references")
            let characters = Array(itemText)
            return String(characters[start..<min(end, characters.count)])
        }
        let body = try XCTUnwrap(pieces.first { $0.startMs <= 200 && 200 < $0.endMs })
        XCTAssertTrue(try passage(ofMarginAt: 200).contains("Levels rose"), "body piece \(body)")
        XCTAssertTrue(try passage(ofMarginAt: 9_900).contains("Supplementary methods"))
    }
}

private final class MediaClockAudioClient: AudioPlaybackClient {
    var mediaTimeMs: Int?
    private var target: String?

    func prepareSpeechText(_ text: String) throws -> String { SpeechTextNormalizer.normalize(text) }
    func play(targetId: String) throws { target = targetId; mediaTimeMs = 0 }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws { target = targetId; self.mediaTimeMs = mediaTimeMs }
    func pause() throws {}
    func stop() throws { target = nil }
    func currentCharOffset() -> Int? { nil }
    func currentRecoveryCharOffset() -> Int? { nil }
    func currentMediaTimeMs() -> Int? { mediaTimeMs }
    func currentPlaybackDurationMs() -> Int? { 10_000 }
    func currentPlaybackPosition() -> PlaybackPosition? {
        mediaTimeMs.map { PlaybackPosition(targetId: target, mediaTimeMs: $0, durationMs: 10_000, playbackRate: 1, anchorConfidence: .mediaTime) }
    }
    func isPlaybackComplete(targetId: String) -> Bool { false }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { .confirmed }
    func isAwaitingRenderedAudio(targetId: String) -> Bool { false }
    func playbackTransportState(targetId: String) -> PlaybackTransportState? { nil }
    func setRemoteCommandHandlingEnabled(_ enabled: Bool) {}
}
