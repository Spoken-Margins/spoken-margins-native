import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #3203: a Lock Screen Mark, and a Watch Margin taken while an article played its publisher's recording, land on the
/// item our player was playing (DESIGN.md section 2 point 12: "It does not make a quick session"), on a real store,
/// and the item still resumes where the listener left it.
final class PlayerItemMarkTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_777_000_000)
    /// 4 Nov 2026, 15:20 UTC, with a part of a millisecond, as a Lock Screen tap is.
    private let taken = Date(timeIntervalSince1970: 1_793_805_600.123_4)
    private let utc = TimeZone(identifier: "UTC")!
    private var root: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("player-item-mark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: An episode

    private func saveEpisode(resumeMs: Int = 421_000) throws -> Session {
        try store.saveItem(Item(
            id: "episode", title: "The Harbour Hour", mediaType: "podcast", text: nil,
            externalReference: "https://example.com/e.mp3", status: "ready", externalReferenceType: "podcast",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/e.mp3", durationMs: 600_000, nativeMediaId: "episode-audio")
        ))
        let session = Session(
            id: "session-episode", itemId: "episode", createdAt: stamp, updatedAt: stamp, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: "episode-audio",
            position: Position(charOffset: 0, mediaTimeMs: resumeMs), completionPercent: 70, playbackRate: 1
        )
        try store.saveSession(session)
        return try XCTUnwrap(store.loadSession(id: session.id))
    }

    func testAMarkLandsOnTheEpisodeAtItsTimeAsAWrittenMarginWithWordsThatSayWhatItIs() throws {
        _ = try saveEpisode()

        let saved = try PlayerItemMargin.placeMark(atMediaTimeMs: 574_000, markedAt: taken, itemId: "episode", repository: store, timeZone: utc)

        XCTAssertEqual(saved.itemId, "episode")
        XCTAssertEqual(saved.sessionId, "session-episode")
        XCTAssertEqual(saved.anchor.mediaTimeMs, 574_000, "the time it was taken, not the resume point 421 s")
        XCTAssertEqual(saved.captureKind, .written)
        XCTAssertNil(saved.audioPath)
        XCTAssertEqual(saved.displayText, "Mark at 9:34 in “The Harbour Hour”, from the Lock Screen on 4 Nov 2026")
        XCTAssertEqual(saved.transcript, saved.displayText, "the words a packet sends (#304) are the words shown")
        XCTAssertEqual(saved.status, "active")
        XCTAssertEqual(saved.createdAt.timeIntervalSince1970, taken.timeIntervalSince1970, accuracy: 1, "dated when it was tapped (the store keeps seconds)")
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-episode").map(\.id), [saved.id])
    }

    func testTheEpisodeStillResumesWhereItWasLeftAfterAMark() throws {
        let before = try saveEpisode()
        let itemBefore = try store.loadItem(id: "episode")

        _ = try PlayerItemMargin.placeMark(atMediaTimeMs: 64_000, markedAt: taken, itemId: "episode", repository: store, timeZone: utc)

        XCTAssertEqual(try store.loadSession(id: before.id), before, "resume point, percent, phase and updatedAt all as they were")
        XCTAssertEqual(try store.loadItem(id: "episode"), itemBefore, "the item itself is untouched")
    }

    func testARetriedMarkWritesNoSecondCopy() throws {
        _ = try saveEpisode()
        let first = try PlayerItemMargin.placeMark(atMediaTimeMs: 64_000, markedAt: taken, itemId: "episode", repository: store, timeZone: utc)
        let again = try PlayerItemMargin.placeMark(atMediaTimeMs: 64_000, markedAt: taken, itemId: "episode", repository: store, timeZone: utc)
        let next = try PlayerItemMargin.placeMark(
            atMediaTimeMs: 70_000, markedAt: taken.addingTimeInterval(6), itemId: "episode", repository: store, timeZone: utc
        )

        XCTAssertEqual(again.id, first.id)
        XCTAssertNotEqual(next.id, first.id, "a second Mark a few seconds later is its own Margin")
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-episode").count, 2)
    }

    func testAMarkPastTheEndOfTheEpisodeStaysInsideIt() throws {
        _ = try saveEpisode()
        let saved = try PlayerItemMargin.placeMark(atMediaTimeMs: 900_000, markedAt: taken, itemId: "episode", repository: store, timeZone: utc)
        XCTAssertEqual(saved.anchor.mediaTimeMs, 599_999)
    }

    func testAMarkTheItemCannotTakeIsRefusedAndLeavesNothing() throws {
        XCTAssertThrowsError(try PlayerItemMargin.placeMark(atMediaTimeMs: 1_000, markedAt: taken, itemId: "gone", repository: store)) {
            XCTAssertEqual($0 as? PlayerItemMargin.Failure, .itemNotFound)
        }
        try store.saveItem(Item(id: "unstarted", title: "Not started", mediaType: "podcast", text: nil, externalReference: nil, status: "ready"))
        XCTAssertThrowsError(try PlayerItemMargin.placeMark(atMediaTimeMs: 1_000, markedAt: taken, itemId: "unstarted", repository: store)) {
            XCTAssertEqual($0 as? PlayerItemMargin.Failure, .noSession, "the receiver files it as a quick session")
        }
    }

    // MARK: The words

    func testMarkWordsTable() {
        let long = String(repeating: "Tides ", count: 20)
        struct Row { var time: Int?; var title: String?; var expected: String }
        let rows = [
            Row(time: 0, title: "Episode", expected: "Mark at 0:00 in “Episode”, from the Lock Screen on 4 Nov 2026"),
            Row(time: 3_725_000, title: "Episode", expected: "Mark at 1:02:05 in “Episode”, from the Lock Screen on 4 Nov 2026"),
            Row(time: 59_999, title: "Episode", expected: "Mark at 0:59 in “Episode”, from the Lock Screen on 4 Nov 2026"),
            Row(time: nil, title: "An article", expected: "Mark in “An article”, from the Lock Screen on 4 Nov 2026"),
            Row(time: 1_000, title: nil, expected: "Mark at 0:01, from the Lock Screen on 4 Nov 2026"),
            Row(time: 1_000, title: " \n\t ", expected: "Mark at 0:01, from the Lock Screen on 4 Nov 2026"),
            Row(time: 1_000, title: "  Two\n lines  ", expected: "Mark at 0:01 in “Two lines”, from the Lock Screen on 4 Nov 2026"),
            Row(time: 1_000, title: "Cafe\u{301}", expected: "Mark at 0:01 in “Caf\u{E9}”, from the Lock Screen on 4 Nov 2026"),
            Row(
                time: 1_000, title: long,
                expected: "Mark at 0:01 in “\(String(long.prefix(79)).trimmingCharacters(in: .whitespaces))…”, from the Lock Screen on 4 Nov 2026"
            )
        ]
        for row in rows {
            let words = PlayerItemMargin.markWords(mediaTimeMs: row.time, itemTitle: row.title, markedAt: taken, timeZone: utc)
            XCTAssertEqual(words, row.expected, String(describing: row.title))
            XCTAssertEqual(words.unicodeScalars.map(\.value), row.expected.precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
        }
        let tokyo = PlayerItemMargin.markWords(mediaTimeMs: nil, itemTitle: "A", markedAt: Date(timeIntervalSince1970: 1_793_833_200), timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertTrue(tokyo.hasSuffix("on 5 Nov 2026"), "the listener's own calendar day: \(tokyo)")
    }

    // MARK: An article playing its publisher's recording

    private let sentences = ["The harbour shelters fishing boats.", "Gulls circle the old pier at dawn."]

    private func saveArticle(withRecording: Bool = true, resumeChar: Int = 3) throws -> Session {
        let text = sentences.joined(separator: " ")
        try store.saveItem(Item(id: "article", title: "A harbour", mediaType: "text", text: text, externalReference: "https://example.com/harbour", status: "ready"))
        if withRecording {
            try store.savePublisherAudio(PublisherAudio(
                itemId: "article", audioURL: "https://publisher.example/recording.mp3", durationMs: 9_000, detectedFrom: "substack_post_voiceover",
                textMap: TranscriptTimeline(segments: [
                    MediaTimelineSegment(id: "p1", startMs: 500, endMs: 4_000, startChar: 0, endChar: sentences[0].count, text: sentences[0]),
                    MediaTimelineSegment(id: "p2", startMs: 4_500, endMs: 8_500, startChar: sentences[0].count + 1, endChar: text.count, text: sentences[1])
                ], chapters: [], durationMs: 9_000),
                textMapStatus: "aligned(2 of 2 sentences)"
            ))
        }
        // As the Library stores an article whose recording plays: in article form, at a text place (#547).
        let session = Session(
            id: "session-article", itemId: "article", createdAt: stamp, updatedAt: stamp, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: "article",
            position: Position(charOffset: resumeChar), completionPercent: 5, playbackRate: 1
        )
        try store.saveSession(session)
        return try XCTUnwrap(store.loadSession(id: session.id))
    }

    func testAWatchMarginTakenWhileThePublisherRecordingPlayedLandsOnTheArticleWordsAtThatTime() throws {
        let before = try saveArticle()

        // 6.5 s into the recording is halfway through the second sentence.
        let saved = try PlayerItemMargin.placeSpoken(
            audioPath: "LiveSessions/w1.m4a", atMediaTimeMs: 6_500, markedAt: taken, itemId: "article", repository: store
        )

        XCTAssertEqual(saved.itemId, "article")
        XCTAssertEqual(saved.sessionId, "session-article")
        XCTAssertEqual(saved.audioPath, "LiveSessions/w1.m4a")
        let second = (sentences[0].count + 1)..<(sentences.joined(separator: " ").count)
        XCTAssertTrue(second.contains(saved.anchor.startChar), "on the sentence the recording was speaking, not the resume point: \(saved.anchor.startChar)")
        XCTAssertEqual(try store.loadSession(id: before.id), before, "the article resumes where it was left")
        XCTAssertEqual(try store.loadInterjections(sessionId: before.id).map(\.id), [saved.id])
    }

    func testAMarkWhileThePublisherRecordingPlayedLandsOnTheArticleWithoutAClock() throws {
        let before = try saveArticle()

        let saved = try PlayerItemMargin.placeMark(atMediaTimeMs: 1_000, markedAt: taken, itemId: "article", repository: store, timeZone: utc)

        XCTAssertTrue((0..<sentences[0].count).contains(saved.anchor.startChar), "on the first sentence: \(saved.anchor.startChar)")
        XCTAssertEqual(saved.displayText, "Mark in “A harbour”, from the Lock Screen on 4 Nov 2026", "an article's place is its words, not a clock")
        XCTAssertEqual(try store.loadSession(id: before.id), before)
    }

    func testAnArticleWithNoRecordingStillGoesToAQuickSession() throws {
        _ = try saveArticle(withRecording: false)
        XCTAssertThrowsError(try PlayerItemMargin.placeSpoken(
            audioPath: "LiveSessions/w1.m4a", atMediaTimeMs: 6_500, markedAt: taken, itemId: "article", repository: store
        )) { XCTAssertEqual($0 as? PlayerItemMargin.Failure, .unsupportedTarget) }
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-article"), [])
    }

    func testAWatchMarginOnThePublisherArticleIsWithdrawnWhenDeletedOnTheWatch() throws {
        let session = try saveArticle()
        let placed = try PlayerItemMargin.placeSpoken(
            audioPath: "LiveSessions/w1.m4a", atMediaTimeMs: 6_500, markedAt: taken, itemId: "article", repository: store
        )

        let touched = PlayerItemMargin.withdraw(audioPath: "LiveSessions/w1.m4a", in: [session], repository: store) { margin in
            try self.store.updateInterjection(id: margin.id, sessionId: margin.sessionId) { $0.status = "deleted" } != nil
        }

        XCTAssertEqual(touched, ["article"])
        XCTAssertEqual(try store.loadInterjections(sessionId: session.id).first { $0.id == placed.id }?.status, "deleted")
    }
}
