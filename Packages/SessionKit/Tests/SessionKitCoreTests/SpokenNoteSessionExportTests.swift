import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// A spoken note's Export Session (#4782): the whole transcript with the Margins in place, by default, for the
/// listener's own note only. Podcasts and audio files keep the bounded window, and every caller that passes no
/// note switch gets exactly the export it got before.
@MainActor
final class SpokenNoteSessionExportTests: XCTestCase {
    private typealias F = SpokenNoteExportFixtures

    private static let margins: [Interjection] = [
        F.margin("on-two", at: 1, mediaTimeMs: 2_400, segmentId: F.segmentId(F.takeA, 1), anchorBefore: "window", anchorAfter: "window"),
        F.margin("on-four-written", at: 3, mediaTimeMs: 7_300, written: true, transcript: "A written thought."),
        F.margin("on-two-later", at: 2, mediaTimeMs: 2_900),
    ]

    private func options(_ noteText: Bool?, fullText: Bool = false, sessionId: String? = F.sessionId) -> ExportOptions {
        ExportOptions(sessionId: sessionId, includeFullText: fullText, includeReference: true, includeListeningMap: false,
                      includeInterjections: true, includeSpokenNoteText: noteText)
    }

    private func repository(item: Item = F.item(), margins: [Interjection] = margins, stored: TranscriptTimeline? = F.storedTimeline()) -> InMemorySessionRepository {
        let session = Session(
            id: F.sessionId, itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: item.id,
            position: Position(mediaTimeMs: 9_000), completionPercent: 95, playbackRate: 1
        )
        return InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session],
            interjections: Dictionary(uniqueKeysWithValues: margins.map { ($0.id, $0) }),
            transcriptTimelines: stored.map {
                [item.id: SourceTranscriptTimeline(id: "transcript-\(item.id)", itemId: item.id, createdAt: Date(timeIntervalSince1970: 1), timeline: $0)]
            } ?? [:]
        )
    }

    private func engine(_ repository: SessionRepository, loader: (@Sendable (Item) -> SpokenNoteExportInput?)? = { _ in F.input() }) -> SessionEngine {
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone-tablet-online", displayName: "Phone/Tablet Online", capabilities: ["sync": ["canonical_persistence"]]),
            repository: repository)
        engine.spokenNoteLoader = loader
        return engine
    }

    private func export(_ noteText: Bool?, repository: SessionRepository? = nil,
                        loader: (@Sendable (Item) -> SpokenNoteExportInput?)? = { _ in F.input() }) async throws -> SessionExport {
        try await engine(repository ?? self.repository(), loader: loader).buildExportReadingOffMain(options: options(noteText))
    }

    // MARK: JSON

    func testWithSourceTextOnTheJSONHoldsTheWholeNoteAndEachMarginsSentence() async throws {
        let export = try await export(true)

        XCTAssertEqual(export.schemaVersion, "spoken-margins.export.v1")
        XCTAssertEqual(export.item.sourceKind, "spoken_note")
        XCTAssertEqual(export.item.mediaSourceType, "native_media_file", "unchanged")
        XCTAssertTrue(export.item.includedFullText)
        XCTAssertEqual(export.item.text, "One. Two. Three. Four. Five.")
        XCTAssertNil(export.item.sourceTranscript)
        let transcript = try XCTUnwrap(export.item.noteTranscript)
        XCTAssertEqual(transcript.source, "note")
        XCTAssertEqual(transcript.recordingCount, 3)
        XCTAssertEqual(transcript.recordingsWithWords, 2)
        XCTAssertEqual(transcript.complete, false)
        XCTAssertEqual(transcript.recordings?.map(\.hasWords), [true, false, true])
        XCTAssertEqual(transcript.recordings?.first?.sentences.first, ExportNoteSentence(segmentId: "note-take-a-1-0", text: "One."))

        XCTAssertEqual(export.interjections.map(\.id), ["on-two", "on-two-later", "on-four-written"], "the order they were made")
        let onTwo = try XCTUnwrap(export.interjections.first)
        XCTAssertEqual(onTwo.sourceSegmentId, "note-take-a-1-1")
        XCTAssertEqual(onTwo.mediaTimeMs, 2_000, "the sentence's start, so Markdown and JSON agree")
        XCTAssertEqual(onTwo.sourceCharOffset, 5)
        XCTAssertEqual(onTwo.anchorBefore, "Two.", "never the stored window")
        XCTAssertEqual(onTwo.anchorAfter, "Three.")
        let written = try XCTUnwrap(export.interjections.last)
        XCTAssertEqual(written.sourceSegmentId, "note-take-c-0")
        XCTAssertEqual(written.mediaTimeMs, 7_000)
    }

    func testWithSourceTextOffTheWordsAreGoneAndEachMarginKeepsOnlyItsSentenceAndTheNext() async throws {
        let export = try await export(false)

        XCTAssertFalse(export.item.includedFullText)
        XCTAssertNil(export.item.text)
        XCTAssertNil(export.item.noteTranscript?.recordings)
        XCTAssertEqual(export.item.noteTranscript?.complete, false, "how complete the note is goes either way")
        XCTAssertEqual(export.interjections.first?.anchorBefore, "Two.")
        XCTAssertEqual(export.interjections.first?.anchorAfter, "Three.")
        let words = export.interjections.flatMap { [$0.anchorBefore, $0.anchorAfter] }.joined(separator: " ")
        XCTAssertFalse(words.contains("One."), "no word beyond each Margin's own pair")
    }

    func testTheArticleSwitchIsIgnoredForANote() async throws {
        let off = try await export(false)
        let offWithArticleOn = try await engine(repository()).buildExportReadingOffMain(options: options(false, fullText: true))
        XCTAssertEqual(off, offWithArticleOn)
    }

    func testWithNoNoteSwitchANoteExportsExactlyAsBefore() async throws {
        let export = try await export(nil)
        XCTAssertNil(export.item.sourceKind)
        XCTAssertNil(export.item.noteTranscript)
        XCTAssertTrue(export.interjections.allSatisfy { $0.sourceSegmentId == nil })
        XCTAssertFalse(export.item.includedFullText, "a note counts as native audio, as before")
        XCTAssertEqual(export.interjections.first { $0.id == "on-two" }?.mediaTimeMs, 2_400, "its stored time, as before")
        let encoded = String(decoding: try JSONEncoder().encode(export), as: UTF8.self)
        XCTAssertFalse(encoded.contains("sourceKind") || encoded.contains("noteTranscript") || encoded.contains("sourceSegmentId"))
    }

    func testAnArticleAndAPodcastAreTheSameWithOrWithoutTheNoteSwitch() async throws {
        for (mediaType, media) in [("article", ItemMedia?.none),
                                   (TargetType.transcriptBackedMedia.rawValue, ItemMedia(sourceType: .remoteStream, url: "https://example.com/e.mp3", durationMs: 10_000))] {
            let item = Item(id: F.itemId, title: "Other", mediaType: mediaType, text: "One. Two. Three. Four. Five.",
                            externalReference: "https://example.com/a", status: "ready", media: media)
            let repository = repository(item: item)
            for fullText in [false, true] {
                let without = try await engine(repository).buildExportReadingOffMain(options: options(nil, fullText: fullText))
                for noteText in [false, true] {
                    let with = try await engine(repository).buildExportReadingOffMain(options: options(noteText, fullText: fullText))
                    XCTAssertEqual(with, without, "\(mediaType) fullText \(fullText) noteText \(noteText)")
                }
            }
        }
    }

    // MARK: Missing words and the fallback

    func testANoteWithNoWordsAtAllSaysSoAndPlacesNothing() async throws {
        let wordless = F.note([F.takeB])
        let export = try await export(true, loader: { _ in SpokenNoteExportInput(note: wordless, wholeTimeline: nil) })
        XCTAssertEqual(export.item.noteTranscript?.recordingsWithWords, 0)
        XCTAssertEqual(export.item.noteTranscript?.complete, false)
        XCTAssertTrue(export.interjections.filter { $0.sourceSegmentId != nil }.isEmpty)
        XCTAssertEqual(export.interjections.first?.anchorBefore, "", "an unplaced Margin has no context")
    }

    func testANilLoaderOrAnUnreadableNoteFileGivesTheLastPlaybackFallback() async throws {
        // Two calls, not a loop over an array literal of an optional closure type: Swift 6.4 crashes its
        // diagnostics on `[nil, { _ in nil }]` ("failed to produce diagnostic for expression").
        try await assertLastPlaybackFallback(loader: nil)
        let unreadable: @Sendable (Item) -> SpokenNoteExportInput? = { _ in nil }
        try await assertLastPlaybackFallback(loader: unreadable)
    }

    private func assertLastPlaybackFallback(loader: (@Sendable (Item) -> SpokenNoteExportInput?)?) async throws {
        let result = try await export(true, loader: loader)
        let transcript = try XCTUnwrap(result.item.noteTranscript)
        XCTAssertEqual(transcript.source, "last_playback")
        XCTAssertNil(transcript.recordingCount)
        XCTAssertNil(transcript.complete)
        XCTAssertEqual(transcript.recordings?.count, 1)
        XCTAssertEqual(result.item.text, "One. Two. Three. Four. Five.")
        XCTAssertEqual(result.interjections.first?.sourceSegmentId, "note-take-a-1-1")
    }

    func testTheSyncExportNeverCallsTheLoader() throws {
        let engine = engine(repository(), loader: { _ in
            XCTFail("the sync path must not read the note file")
            return nil
        })
        let export = try engine.buildExport(options: options(true))
        XCTAssertEqual(export.item.noteTranscript?.source, "last_playback")
    }

    func testWithNoLoaderTheOffMainExportIsTheSyncExportForBothSwitchValues() async throws {
        for noteText in [false, true] {
            let engine = engine(repository(), loader: nil)
            let offMain = try await engine.buildExportReadingOffMain(options: options(noteText))
            XCTAssertEqual(offMain, try engine.buildExport(options: options(noteText)), "noteText \(noteText)")
        }
    }

    func testACorruptNoteFileFallsBackWithoutChangingIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("note-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = SpokenNoteStore(folderURL: folder, noteId: F.noteId)
        try Data("{ not json".utf8).write(to: store.fileURL)
        let export = try await export(true, loader: { _ in store.peek().map { SpokenNoteExportInput(note: $0, wholeTimeline: nil) } })
        XCTAssertEqual(export.item.noteTranscript?.source, "last_playback")
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), "{ not json", "the export only reads")
    }

    // MARK: Device conditions

    func testRelaunchOverTheSameStoreAndNoteFolderGivesTheSameExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("note-relaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let noteStore = SpokenNoteStore(folderURL: folder.appendingPathComponent("note"), noteId: F.noteId)
        try noteStore.save(F.note())
        let path = folder.appendingPathComponent("library.sqlite").path
        do {
            let store = try SQLiteSessionStore(path: path)
            let seed = repository()
            try store.saveItem(F.item())
            try store.saveSession(XCTUnwrap(seed.loadSession(id: F.sessionId)))
            for margin in Self.margins { try store.saveInterjection(margin) }
            try store.saveTranscriptTimeline(SourceTranscriptTimeline(id: "transcript-\(F.itemId)", itemId: F.itemId,
                                                                      createdAt: Date(timeIntervalSince1970: 1), timeline: F.storedTimeline()))
        }
        let loader: @Sendable (Item) -> SpokenNoteExportInput? = { _ in
            noteStore.peek().map { SpokenNoteExportInput(note: $0, wholeTimeline: F.whole()) }
        }
        let first = try await engine(try SQLiteSessionStore(path: path), loader: loader).buildExportReadingOffMain(options: options(true))
        let second = try await engine(try SQLiteSessionStore(path: path), loader: loader).buildExportReadingOffMain(options: options(true))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.interjections.count, 3)
        XCTAssertEqual(first.item.text, F.note().text)
    }

    func testAnUnsavedTakeIsNotCounted() async throws {
        // The listener is recording a fourth take: it isn't in note.json yet, so the export is the same with or without it.
        let before = try await export(true)
        let after = try await export(true)
        XCTAssertEqual(before, after)
        XCTAssertEqual(before.item.noteTranscript?.recordingCount, 3)
    }

    // MARK: Markdown

    func testTheMarkdownPutsEachMarginUnderItsSentenceWithRecordingHeadings() async throws {
        let markdown = SessionExportMarkdownRenderer.render(try await export(true))
        XCTAssertTrue(markdown.contains("Source Type: spoken_note\n"))
        XCTAssertFalse(markdown.contains("## Source Text"))
        XCTAssertFalse(markdown.contains("## Source Transcript"))
        XCTAssertFalse(markdown.contains("## Timeline"), "every Margin sits in the note's section, so nothing is left for it")
        let expected = """
        ## Spoken Note Transcript with Margins

        Transcript incomplete: 1 of 3 recordings has no words written down yet. Only the words that exist are below.

        ### Recording 1

        One. Two.

        #### 0:02 — Listener interjection

        Margin on-two.

        #### 0:02 — Listener interjection

        Margin on-two-later.

        Three.

        ### Recording 2

        No words written down yet for this recording.

        ### Recording 3

        Four.

        #### 0:07 — Listener interjection

        Written Margin:
        A written thought.

        Five.

        ## Session
        """
        XCTAssertTrue(markdown.contains(expected), markdown)
    }

    func testTheMarkdownWithSourceTextOffHasNoTranscriptAndUsesTheContextBlock() async throws {
        let markdown = SessionExportMarkdownRenderer.render(try await export(false))
        XCTAssertFalse(markdown.contains("## Spoken Note Transcript"))
        XCTAssertTrue(markdown.contains("## Timeline"))
        XCTAssertTrue(markdown.contains("### Source Context and Listener Interjections"))
        XCTAssertTrue(markdown.contains("Source context:\nTwo."))
        XCTAssertFalse(markdown.contains("One."))
    }

    func testAOneTakeNoteReadsAsProseAndUnplacedMarginsAreListedApart() async throws {
        let note = F.note([F.takeA])
        let margins = [
            F.margin("last", at: 1, mediaTimeMs: 3_500),
            F.margin("nowhere", at: 2, noPlace: true),
            F.margin("turn-margin", at: 3, targetType: .assistantTurn, targetId: "turn-x"),
        ]
        let export = try await export(true, repository: repository(margins: margins),
                                      loader: { _ in SpokenNoteExportInput(note: note, wholeTimeline: F.whole([F.takeA])) })
        let markdown = SessionExportMarkdownRenderer.render(export)
        XCTAssertFalse(markdown.contains("### Recording"))
        XCTAssertFalse(markdown.contains("Transcript incomplete"))
        XCTAssertTrue(markdown.contains("One. Two. Three.\n\n#### 0:03 — Listener interjection\n\nMargin last.\n\n### Margins not placed in the note\n\n#### No place saved — Listener interjection\n\nMargin nowhere."), markdown)
        XCTAssertTrue(markdown.contains("## Timeline"), "a Margin on an AI reply stays in the Timeline")
        XCTAssertEqual(markdown.components(separatedBy: "Margin last.").count, 2, "never repeated")
    }

    func testTheMarkdownFallbackSaysWhereItsWordsCameFrom() async throws {
        let markdown = SessionExportMarkdownRenderer.render(try await export(true, loader: nil))
        XCTAssertTrue(markdown.contains("## Spoken Note Transcript with Margins\n\nRecording details unavailable. These are the words from this note's last playback.\n\nOne. Two.\n"), markdown)
        XCTAssertFalse(markdown.contains("### Recording"))
    }

    func testTheMarkdownForUnreadableWordsAndForANoteWithNoWords() async throws {
        let noRow = try await export(true, repository: repository(item: F.item(text: ""), stored: nil), loader: nil)
        let unreadable = SessionExportMarkdownRenderer.render(noRow)
        XCTAssertTrue(unreadable.contains("## Spoken Note Transcript\n\nThis note's words couldn't be read.\n\n### Margins not placed in the note"), unreadable)

        let wordless = F.note([F.takeB])
        let none = SessionExportMarkdownRenderer.render(try await export(true, loader: { _ in SpokenNoteExportInput(note: wordless, wholeTimeline: nil) }))
        XCTAssertTrue(none.contains("## Spoken Note Transcript\n\nNo words written down yet for this note.\n\n### Margins not placed in the note"), none)
        XCTAssertFalse(none.contains("Transcript incomplete"))
    }

    func testTheIncompleteLineSaysHaveForMoreThanOne() {
        XCTAssertEqual(SpokenNoteMarkdownSection.incompleteLine(missing: 2, of: 3),
                       "Transcript incomplete: 2 of 3 recordings have no words written down yet. Only the words that exist are below.")
    }

    func testALongNoteHasEverySentenceAndEveryMarginOnce() async throws {
        let takes = (0..<3).map { takeIndex in
            SpokenNoteTake(
                id: "long-\(takeIndex)", audioFileName: "long-\(takeIndex).m4a", durationMs: 2_400_000, createdAt: Date(),
                sentences: (0..<1_000).map { SpokenNoteSentence(text: "S\(takeIndex)x\($0).", startMs: $0 * 2_400, endMs: $0 * 2_400 + 2_000) }
            )
        }
        let whole = F.whole(takes)
        let margins = (0..<200).map { F.margin("m\($0)", at: Double($0), mediaTimeMs: $0 * 36_000, transcript: "Thought \($0)#") }
        let export = try await export(true, repository: repository(margins: margins, stored: whole.mediaTimeline),
                                      loader: { _ in SpokenNoteExportInput(note: F.note(takes), wholeTimeline: whole) })
        let markdown = SessionExportMarkdownRenderer.render(export)
        XCTAssertEqual(markdown.components(separatedBy: "Thought ").count - 1, 200)
        for index in [0, 999] {
            for takeIndex in 0..<3 { XCTAssertTrue(markdown.contains("S\(takeIndex)x\(index).")) }
        }
        XCTAssertEqual(export.item.noteTranscript?.recordings?.flatMap(\.sentences).count, 3_000)
    }
}

final class SpokenNoteExportFootnoteTests: XCTestCase {
    private func transcript(_ source: String, count: Int? = nil, withWords: Int? = nil, recordings: [ExportNoteRecording]? = []) -> ExportNoteTranscript {
        ExportNoteTranscript(source: source, recordingCount: count, recordingsWithWords: withWords, complete: nil, recordings: recordings)
    }

    func testNoRecordingHasWords() {
        XCTAssertEqual(SpokenNoteExportFootnote.text(for: transcript("note", count: 2, withWords: 0), includesText: true),
                       "This note has no words written down yet.")
    }

    func testSomeRecordingsHaveNoWords() {
        XCTAssertEqual(SpokenNoteExportFootnote.text(for: transcript("note", count: 3, withWords: 2), includesText: true),
                       "1 of 3 recordings has no words yet. The file says which.")
        XCTAssertEqual(SpokenNoteExportFootnote.text(for: transcript("note", count: 3, withWords: 1), includesText: true),
                       "2 of 3 recordings have no words yet. The file says which.")
    }

    func testTheFallbackWithAndWithoutWords() {
        let words = [ExportNoteRecording(number: 1, hasWords: true, sentences: [ExportNoteSentence(segmentId: "s", text: "Hi.")])]
        XCTAssertEqual(SpokenNoteExportFootnote.text(for: transcript("last_playback", recordings: words), includesText: true),
                       "Some of this note's details couldn't be read. The file has the words from its last playback.")
        let none = [ExportNoteRecording(number: 1, hasWords: false, sentences: [])]
        XCTAssertEqual(SpokenNoteExportFootnote.text(for: transcript("last_playback", recordings: none), includesText: true),
                       "This note's words couldn't be read.")
    }

    func testNoneWhenCompleteWhenOffOrWithNoPreview() {
        XCTAssertNil(SpokenNoteExportFootnote.text(for: transcript("note", count: 2, withWords: 2), includesText: true))
        XCTAssertNil(SpokenNoteExportFootnote.text(for: transcript("note", count: 2, withWords: 0), includesText: false))
        XCTAssertNil(SpokenNoteExportFootnote.text(for: nil, includesText: true))
    }
}
