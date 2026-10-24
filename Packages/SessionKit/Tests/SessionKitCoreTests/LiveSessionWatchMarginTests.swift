import Foundation
import XCTest
@testable import SessionKit

/// #2487: a spoken Margin from the Watch lands in the live session it was spoken in, once, and is written onto the
/// session's item as a spoken Margin.
final class LiveSessionWatchMarginTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // The span matching moved to `LiveSessionFiling` (slice 1a): see LiveSessionFilingTests.

    // MARK: Metadata and attaching

    func testMetadataRoundTripsAndRejectsOtherTransfers() throws {
        let transfer = WatchMarginTransfer(id: "A1", wallStart: t0.addingTimeInterval(12.5), durationMs: 4_250)
        let read = try XCTUnwrap(WatchMarginTransfer(metadata: transfer.metadata))
        XCTAssertEqual(read.id, "A1")
        XCTAssertEqual(read.wallStart.timeIntervalSince1970, transfer.wallStart.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(read.durationMs, 4_250)
        XCTAssertNil(WatchMarginTransfer(metadata: nil))
        XCTAssertNil(WatchMarginTransfer(metadata: ["id": "A1", "wallStart": 1.0]), "no kind: some other transfer")
        var noStart = transfer.metadata
        noStart[WatchMarginTransfer.Key.wallStart] = nil
        XCTAssertNil(WatchMarginTransfer(metadata: noStart))
        var blankId = transfer.metadata
        blankId[WatchMarginTransfer.Key.id] = "  "
        XCTAssertNil(WatchMarginTransfer(metadata: blankId))
    }

    func testAudioPathIsARecorderStylePathEvenForAStrangeId() {
        let transfer = WatchMarginTransfer(id: "../../etc/x y", wallStart: t0, durationMs: 1)
        XCTAssertEqual(transfer.audioPath, "SpokenMargins/interjections/watch-______etc_x_y.m4a")
    }

    func testADuplicateIdIsIgnored() {
        var live = LiveSession(id: "live", startedAt: t0)
        let transfer = WatchMarginTransfer(id: "A1", wallStart: t0.addingTimeInterval(90), durationMs: 3_000)
        XCTAssertTrue(live.attach(transfer))
        XCTAssertFalse(live.attach(transfer))
        XCTAssertEqual(live.margins.count, 1)
        XCTAssertEqual(live.margins[0].sessionOffsetMs, 90_000)
        XCTAssertEqual(live.margins[0].spokenOn, "watch")
        XCTAssertEqual(live.margins[0].savedText, "Spoken Margin")
    }

    func testAMarginBeforeTheStartIsKeptAtZero() {
        var live = LiveSession(id: "live", startedAt: t0)
        live.attach(WatchMarginTransfer(id: "early", wallStart: t0.addingTimeInterval(-30), durationMs: 1_000))
        XCTAssertEqual(live.margins.first?.sessionOffsetMs, 0)
        let placed = LiveSessionAlignment.place(live.margins, recordingStart: t0, durationMs: 60_000)
        XCTAssertEqual(placed.first?.clamp, .beforeStart)
        XCTAssertEqual(placed.first?.audioPath, "SpokenMargins/interjections/watch-early.m4a")
    }

    func testTranscriptFillsOnlyAnEmptySpokenMargin() {
        var live = LiveSession(id: "live", startedAt: t0, margins: [LiveSessionMargin(id: "w", text: "typed", markedAt: t0)])
        live.attach(WatchMarginTransfer(id: "A1", wallStart: t0, durationMs: 1_000))
        XCTAssertFalse(live.setTranscript("words", forMarginId: "w"), "a written Margin is not a recording")
        XCTAssertTrue(live.setTranscript("Johnny was talking about the budget", forMarginId: "watch-A1"))
        XCTAssertFalse(live.setTranscript("again", forMarginId: "watch-A1"), "never overwrites")
        XCTAssertEqual(live.margins.first { $0.id == "watch-A1" }?.spokenTranscript, "Johnny was talking about the budget")
    }

    func testASessionSavedByAnEarlierBuildStillReads() throws {
        let json = #"{"id":"live","kind":"meeting","title":"","startedAt":"2027-01-15T08:00:00.000Z","margins":[{"id":"m","text":"hi","markedAt":"2027-01-15T08:00:01.000Z","sessionOffsetMs":1000,"isBlindMark":false}]}"#
        let directory = FileManager.default.temporaryDirectory.appending(path: "live-watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: LiveSessionStore.url(in: directory).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: LiveSessionStore.url(in: directory))
        let read = try XCTUnwrap(LiveSessionStore.load(from: directory))
        XCTAssertNil(read.margins.first?.audioPath)
        XCTAssertEqual(read.margins.first?.savedText, "hi")
    }

    // MARK: Writing onto the item

    func testSpokenMarginsAreWrittenAsSpokenMarginsWithTheirTranscript() throws {
        let item = Item(
            id: "audiobook-rec", title: "Meeting", mediaType: "audiobook", text: nil,
            externalReference: "file:///tmp/rec.mp4", status: "ready", externalReferenceType: "audiobook",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/rec.mp4", durationMs: 120_000, nativeMediaId: "audiobook-audio-rec")
        )
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [:], interjections: [:])
        var heard = LiveSessionAlignment.Placed(id: "s1", text: "About the budget", offsetMs: 30_000)
        heard.audioPath = "SpokenMargins/interjections/watch-a.m4a"
        heard.transcript = "About the budget"
        var untranscribed = LiveSessionAlignment.Placed(id: "s2", text: "Spoken Margin", offsetMs: 60_000)
        untranscribed.audioPath = "SpokenMargins/interjections/watch-b.m4a"
        let written = LiveSessionAlignment.Placed(id: "w", text: "Typed", offsetMs: 45_000)

        let saved = try LiveSessionMarginPlacer.place([untranscribed, written, heard], itemId: item.id, repository: repo)

        XCTAssertEqual(saved.map(\.anchor.mediaTimeMs), [30_000, 45_000, 60_000])
        XCTAssertEqual(saved.map(\.audioPath), ["SpokenMargins/interjections/watch-a.m4a", nil, "SpokenMargins/interjections/watch-b.m4a"])
        XCTAssertEqual(saved[0].displayText, "About the budget")
        XCTAssertEqual(saved[0].transcriptionStatus, "transcribed")
        XCTAssertTrue(saved[0].isSpokenItemMargin)
        XCTAssertEqual(saved[1].captureKind, .written)
        XCTAssertNil(saved[2].transcript)
        XCTAssertEqual(saved[2].transcriptionStatus, "pending", "left for the app's own Margin transcription")
        let session = try XCTUnwrap(repo.loadSessions(itemId: item.id).first)
        XCTAssertEqual(session.position.mediaTimeMs, 0)
        XCTAssertEqual(try repo.loadInterjections(sessionId: session.id).count, 3)
    }
}
