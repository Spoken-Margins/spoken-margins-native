import Foundation
import XCTest
@testable import SessionKit

/// #2481: every Margin keeps all its position evidence; the player uses the best; the Markdown shows them all.
final class LiveSessionMarkdownTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let start = ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z")!

    private func record() -> LiveSessionRecord {
        var live = LiveSession(id: "s", kind: .meeting, title: "Budget sync", startedAt: start, endedAt: start.addingTimeInterval(900), startPositionMs: 0)
        var slid = live.margin(id: "a", text: "Johnny was just talking about the travel budget", markedAt: start.addingTimeInterval(170))
        slid.listenerPositionMs = 150_000
        live.margins = [slid, live.margin(id: "b", text: "", markedAt: start.addingTimeInterval(400), isBlindMark: true)]
        let transcript = ImportedTranscript(format: .webVTT, cues: [
            TranscriptCue(startMs: 0, endMs: 60_000, speaker: "Alice", text: "Welcome everyone."),
            TranscriptCue(startMs: 120_000, endMs: 180_000, speaker: "Johnny Rivera", text: "The travel budget is over by a third."),
            TranscriptCue(startMs: 600_000, endMs: 660_000, speaker: "Alice", text: "Thanks all.")
        ])
        let result = TranscriptAlignment.align(session: live, transcript: transcript)
        return LiveSessionRecord(itemId: "item-1", session: live, transcript: transcript, placed: result.placed)
    }

    func testEvidenceIsKeptAndTheMatchPlacesTheMargin() {
        let placed = record().placed
        let slid = placed.first { $0.id == "a" }!
        XCTAssertEqual(slid.source, .transcriptMatch)
        XCTAssertEqual(slid.offsetMs, 120_000)
        XCTAssertEqual(slid.listenerMs, 150_000)
        XCTAssertEqual(slid.estimateMs, 170_000)
        XCTAssertEqual(slid.matchSpeaker, "Johnny Rivera")
        XCTAssertEqual(slid.matchScore ?? 0, 1, accuracy: 1e-9)
        let mark = placed.first { $0.id == "b" }!
        XCTAssertEqual(mark.source, .estimate)
        XCTAssertNil(mark.matchMs)
    }

    func testBestEvidenceOrder() {
        XCTAssertEqual(LiveSessionAlignment.best(estimateMs: 1, listenerMs: 2, matchMs: 3).source, .transcriptMatch)
        XCTAssertEqual(LiveSessionAlignment.best(estimateMs: 1, listenerMs: 2, matchMs: nil).offsetMs, 2)
        XCTAssertEqual(LiveSessionAlignment.best(estimateMs: 1, listenerMs: nil, matchMs: nil).source, .estimate)
    }

    func testMarkdownShowsEveryPositionAndTheMatchedLine() {
        let markdown = LiveSessionMarkdown.render(record(), timeZone: utc)
        XCTAssertTrue(markdown.hasPrefix("# Budget sync\n\n- Kind: Meeting\n- Date: 2026-03-04 10:00 to 10:15\n- Started at: 0:00\n"), markdown)
        XCTAssertTrue(markdown.contains("## 1. 2:00\n\nJohnny was just talking about the travel budget\n\nPosition: Transcript match 100% at 2:00 · you set 2:30 · estimate about 2:50 · 2:50 into the session\n\n> Johnny Rivera: The travel budget is over by a third."), markdown)
        XCTAssertTrue(markdown.contains("## 2. About 6:40\n\n_Mark, no words._\n\nPosition: Estimate about 6:40 · 6:40 into the session"), markdown)
        XCTAssertTrue(markdown.contains("## Appendix: transcript\n\n[0:00] **Alice:** Welcome everyone."), markdown)
        XCTAssertFalse(LiveSessionMarkdown.render(record(), includeTranscript: false, timeZone: utc).contains("Appendix"))
    }

    func testRecordRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "record-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = record()
        try original.save(in: directory)
        let loaded = try XCTUnwrap(LiveSessionRecord.load(itemId: "item-1", from: directory))
        XCTAssertEqual(loaded.placed, original.placed)
        XCTAssertEqual(loaded.transcript, original.transcript)
        XCTAssertEqual(loaded.session.margins.map(\.id), original.session.margins.map(\.id))
    }
}
