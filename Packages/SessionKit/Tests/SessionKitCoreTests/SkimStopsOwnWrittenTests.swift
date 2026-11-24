import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4938: the listener's own written Margins are Skim stops, silent like a friend's (#4934): no lead-in, no voice. Which of
/// them are stops, and the ties with chapters, voiced Margins and a friend's silent stops.
final class SkimStopsOwnWrittenTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    private func note(
        _ id: String, ms: Int? = nil, char: Int = 0, captureKind: InterjectionCaptureKind? = .written,
        targetType: InterjectionTargetType = .item, status: String = "active", audioPath: String? = nil,
        words: String = "A note", placeKnown: Bool = true, replyTo: MarginReplyLink? = nil
    ) -> Interjection {
        var margin = Interjection(
            id: id, itemId: "item-1", sessionId: "session", targetType: targetType, targetId: "item-1", createdAt: created,
            roughPercent: 10,
            anchor: Anchor(
                anchorType: ms == nil ? .text : .media, startChar: char, endChar: char + 5, anchorBefore: "", anchorAfter: "",
                mediaTimeMs: ms),
            audioPath: audioPath, audioStatus: "saved", transcriptionStatus: "complete", transcript: words, cleanedTranscript: nil,
            displayText: words, status: status, captureKind: captureKind, replyTo: replyTo)
        if !placeKnown {
            margin.movedOrigin = MovedMarginOrigin(
                marginId: id, itemId: "item-1", sessionId: "session", liveMarginId: "l", fromLiveSessionId: "live",
                fromLiveSessionTitle: "Quick", markedAt: created, movedAt: created, placeKnown: false)
        }
        return margin
    }

    private func friend(_ id: String, ms: Int) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: "layer-1", packageScopedId: "pkg::\(id)", createdAt: created,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: ms),
            approvedTranscript: "A thought.", audioPath: nil,
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: ms, confidence: 1),
            senderReadAloud: false)
    }

    private func mediaChapter(_ id: String, _ ms: Int) -> MediaTimelineChapter {
        MediaTimelineChapter(id: id, title: id, startMs: ms, transcriptSegmentId: "segment-\(id)")
    }

    private func stops(
        own: [Interjection] = [], ownWritten: [Interjection], chapters: [MediaTimelineChapter] = [],
        silentShared: [ImportedCommentaryInterjection] = []
    ) -> SkimStops {
        SkimStopRouting.stops(
            textChapters: [], mediaChapters: chapters, ownMargins: own, sharedMargins: [], silentSharedMargins: silentShared,
            silentOwnMargins: ownWritten, unit: .milliseconds)
    }

    // MARK: Which notes are stops (Done when 3)

    func testWhichOwnMarginsAreSilentStops() {
        let reply = MarginReplyLink(conversationId: "c", parentPackageDigest: "d", parentPackageScopedId: "p")
        let rows: [(String, Interjection, Bool)] = [
            ("an active written item Margin with a place", note("n", ms: 60_000), true),
            ("inactive", note("n", ms: 60_000, status: "deleted"), false),
            ("on an assistant turn", note("n", ms: 60_000, targetType: .assistantTurn), false),
            ("on a summary turn", note("n", ms: 60_000, targetType: .summaryTurn), false),
            ("spoken: it goes through ownMargins", note("n", ms: 60_000, captureKind: .audio, audioPath: "n.m4a"), false),
            ("from before written Margins (nil kind)", note("n", ms: 60_000, captureKind: nil), false),
            ("moved with no saved place", note("n", ms: 60_000, placeKnown: false), false),
            ("a media item and no media time", note("n", ms: nil), false),
            ("a written reply to a friend", note("n", ms: 60_000, replyTo: reply), true),
        ]
        for (name, margin, isStop) in rows {
            let list = stops(ownWritten: [margin])
            XCTAssertEqual(list.stops.count, isStop ? 1 : 0, name)
            if let stop = list.stops.first {
                XCTAssertTrue(stop.isSilent, name)
                XCTAssertTrue(stop.isOwnWritten, name)
                XCTAssertEqual(stop.kind, .margin, "still a Margin, so it beats the scene summary: \(name)")
                XCTAssertEqual(stop.position, 60_000, name)
                XCTAssertNil(list.next(playhead: 0)?.leadInStart, "no lead-in: \(name)")
            }
        }
    }

    func testTheOwnMarginsInputIsUnchanged() {
        // A spoken own Margin is a voiced stop with its lead-in; nothing about it is own-written.
        let spoken = note("v", ms: 90_000, captureKind: .audio, audioPath: "v.m4a")
        let list = stops(own: [spoken], ownWritten: [])
        let target = list.next(playhead: 0)
        XCTAssertEqual(target?.stop.id, "v")
        XCTAssertEqual(target?.stop.isSilent, false)
        XCTAssertEqual(target?.stop.isOwnWritten, false)
        XCTAssertEqual(target?.leadInStart, 60_000)
    }

    // MARK: Ties

    func testANoteOnTopOfAnotherStopIsDropped() {
        let spoken = note("v", ms: 200_000, captureKind: .audio, audioPath: "v.m4a")
        let list = stops(
            own: [spoken],
            ownWritten: [note("by-chapter", ms: 100_800), note("by-voice", ms: 199_000), note("by-friend", ms: 300_500),
                         note("alone", ms: 400_000), note("just-clear", ms: 101_001)],
            chapters: [mediaChapter("c", 100_000)],
            silentShared: [friend("f", ms: 300_000)])
        XCTAssertEqual(list.stops.map(\.id), ["c", "just-clear", "v", "f", "alone"])
        XCTAssertEqual(list.stops.first { $0.id == "f" }?.isOwnWritten, false, "on a tie the friend's stop is kept")
    }

    func testTwoOwnNotesCloseTogetherAreBothStops() {
        let list = stops(ownWritten: [note("a", ms: 10_000), note("b", ms: 10_500)])
        XCTAssertEqual(list.stops.map(\.id), ["a", "b"])
    }

    func testTheSameRowsInCharacters() {
        let unit = SkimStops.PositionUnit.characters(perSecond: 15)
        let chapter = Chapter(id: "c", title: "C", startChar: 300, endChar: 900, percent: 30)
        let list = SkimStopRouting.stops(
            textChapters: [chapter], mediaChapters: [], ownMargins: [], sharedMargins: [],
            silentOwnMargins: [note("same", char: 300), note("next", char: 301), note("far", char: 800),
                               note("off", char: 500, status: "deleted")],
            unit: unit)
        XCTAssertEqual(list.stops.map(\.id), ["c", "next", "far"], "only the same character ties in text")
        XCTAssertTrue(list.stops.dropFirst().allSatisfy(\.isOwnWritten))
    }

    // MARK: Starting states

    func testAReturningListenersLockScreenMarkIsAStop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("own-written-mark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        try store.saveItem(Item(
            id: "episode", title: "The Harbour Hour", mediaType: "podcast", text: nil,
            externalReference: "https://example.com/e.mp3", status: "ready", externalReferenceType: "podcast",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/e.mp3", durationMs: 600_000, nativeMediaId: "episode-audio")))
        try store.saveSession(Session(
            id: "session-episode", itemId: "episode", createdAt: created, updatedAt: created, status: "in_progress",
            phase: .itemPlayback, currentTargetType: .transcriptBackedMedia, currentTargetId: "episode-audio",
            position: Position(charOffset: 0, mediaTimeMs: 0), completionPercent: 0, playbackRate: 1))

        let mark = try PlayerItemMargin.placeMark(
            atMediaTimeMs: 574_000, markedAt: created, itemId: "episode", repository: store, timeZone: TimeZone(identifier: "UTC")!)

        let list = SkimStopRouting.stops(
            textChapters: [], mediaChapters: [], ownMargins: [], sharedMargins: [], silentOwnMargins: [mark], unit: .milliseconds)
        XCTAssertEqual(list.stops.map(\.id), [mark.id])
        XCTAssertEqual(list.stops.first?.position, 574_000)
        let landing = try XCTUnwrap(SilentMarginLanding(own: list.stops[0], in: list, margins: [mark], itemId: "episode"))
        XCTAssertEqual(landing.words, mark.displayText, "a Mark's words show as they are")
    }

    func testALongRecordingWithThreeHundredNotes() throws {
        // Two hours, a note every 24 s, and a chapter every ten minutes.
        let notes = (0..<300).map { note("n\($0)", ms: 1_000 + $0 * 24_000) }
        let chapters = (0..<12).map { mediaChapter("c\($0)", $0 * 600_000) }
        let started = Date()
        let list = stops(ownWritten: notes, chapters: chapters)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a generous ceiling: the arrows read the list while a view builds")
        let stopIds = Set(list.stops.map(\.id))
        for margin in notes where !stopIds.contains(margin.id) {
            let ms = try XCTUnwrap(margin.anchor.mediaTimeMs)
            XCTAssertTrue(chapters.contains { abs($0.startMs - ms) <= SkimStopRouting.silentStopTieMs }, "\(margin.id) dropped only on a tie")
        }
        for stop in list.stops where stop.isOwnWritten {
            let landing = try XCTUnwrap(SilentMarginLanding(own: stop, in: list, margins: notes, itemId: "item-1"))
            XCTAssertTrue(landing.notes.allSatisfy { $0.position - stop.position <= SilentMarginLanding.gatherMs }, stop.id)
            XCTAssertEqual(landing.notes.first?.marginId, stop.id)
        }
    }
}
