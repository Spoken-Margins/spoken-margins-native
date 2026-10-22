import Foundation
import XCTest
@testable import SessionKit

/// #2481: a live session's Margins keep wall-clock times, line up with a recording by its start date and a
/// nudge, and land on the recording's item at those times.
final class LiveSessionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ offsets: [Double], blind: Set<Int> = []) -> LiveSession {
        LiveSession(
            id: "live-1",
            startedAt: t0,
            margins: offsets.enumerated().map { index, seconds in
                LiveSessionMargin(id: "m\(index)", text: blind.contains(index) ? "" : "Note \(index)", markedAt: t0.addingTimeInterval(seconds), isBlindMark: blind.contains(index))
            }
        )
    }

    // MARK: Recording start

    func testRecordingStartPrefersMetadataThenFileDateThenSessionStart() {
        let live = session([10])
        let meta = t0.addingTimeInterval(-30)
        let file = t0.addingTimeInterval(600)
        XCTAssertEqual(LiveSessionAlignment.recordingStart(metadataCreationDate: meta, fileCreationDate: file, session: live).source, .metadata)
        XCTAssertEqual(LiveSessionAlignment.recordingStart(metadataCreationDate: meta, fileCreationDate: file, session: live).date, meta)
        XCTAssertEqual(LiveSessionAlignment.recordingStart(metadataCreationDate: nil, fileCreationDate: file, session: live).source, .fileDate)
        let none = LiveSessionAlignment.recordingStart(metadataCreationDate: nil, fileCreationDate: nil, session: live)
        XCTAssertEqual(none.source, .sessionStart)
        XCTAssertEqual(none.date, t0)
    }

    func testDatesFarFromTheSessionAreIgnored() {
        let live = session([10])
        let stale = t0.addingTimeInterval(-3 * 86_400)
        let result = LiveSessionAlignment.recordingStart(metadataCreationDate: stale, fileCreationDate: stale, session: live)
        XCTAssertEqual(result.source, .sessionStart)
    }

    // MARK: Placement

    func testMarginsLandAtWallTimeMinusRecordingStart() {
        let live = session([5, 65.25])
        let placed = LiveSessionAlignment.place(live.margins, recordingStart: t0.addingTimeInterval(-10), durationMs: 600_000)
        XCTAssertEqual(placed.map(\.offsetMs), [15_000, 75_250])
        XCTAssertEqual(placed.map(\.clamp), [nil, nil])
    }

    func testPositiveNudgeMovesMarginsEarlier() {
        let live = session([30])
        let placed = LiveSessionAlignment.place(live.margins, recordingStart: t0, nudgeMs: 2_500, durationMs: nil)
        XCTAssertEqual(placed.first?.offsetMs, 27_500)
        let back = LiveSessionAlignment.place(live.margins, recordingStart: t0, nudgeMs: -2_500, durationMs: nil)
        XCTAssertEqual(back.first?.offsetMs, 32_500)
    }

    func testMarginsOutsideTheRecordingAreClampedNotDropped() {
        let live = session([-20, 30, 900])
        let placed = LiveSessionAlignment.place(live.margins, recordingStart: t0, durationMs: 120_000)
        XCTAssertEqual(placed.map(\.offsetMs), [0, 30_000, 119_999])
        XCTAssertEqual(placed.map(\.clamp), [.beforeStart, nil, .afterEnd])
    }

    func testUnknownDurationLeavesTheEndUnclamped() {
        let placed = LiveSessionAlignment.place(session([900]).margins, recordingStart: t0, durationMs: nil)
        XCTAssertEqual(placed.first?.offsetMs, 900_000)
        XCTAssertNil(placed.first?.clamp)
    }

    func testBlindMarksSaveAsMarkAndOrderIsByTime() {
        var live = session([50, 10], blind: [0])
        live.margins[0].text = "   "
        let placed = LiveSessionAlignment.place(live.margins, recordingStart: t0, durationMs: nil)
        XCTAssertEqual(placed.map(\.text), ["Note 1", "Mark"])
    }

    // MARK: Marks and storage

    func testMergeMarksSkipsDuplicatesAndSorts() {
        var live = session([30])
        let a = t0.addingTimeInterval(10)
        let b = t0.addingTimeInterval(40)
        XCTAssertEqual(live.mergeMarks([b, a, a]), 2)
        XCTAssertEqual(live.mergeMarks([a]), 0)
        XCTAssertEqual(live.margins.map(\.markedAt), [a, t0.addingTimeInterval(30), b])
        XCTAssertEqual(live.margins.filter(\.isBlindMark).count, 2)
    }

    func testStoreRoundTripsMillisecondTimes() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "live-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var live = session([1.234])
        live.endedAt = t0.addingTimeInterval(60)
        try LiveSessionStore.save(live, in: directory)
        let read = try XCTUnwrap(LiveSessionStore.load(from: directory))
        XCTAssertEqual(read.margins[0].markedAt.timeIntervalSince1970, live.margins[0].markedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(read.endedAt, live.endedAt)
        LiveSessionStore.remove(from: directory)
        XCTAssertNil(LiveSessionStore.load(from: directory))
    }

    // MARK: Writing onto the recording's item

    private func audioItem(durationMs: Int?) -> Item {
        Item(
            id: "audiobook-rec", title: "Meeting", mediaType: "audiobook", text: nil,
            externalReference: "file:///tmp/rec.mp4", status: "ready", externalReferenceType: "audiobook",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/rec.mp4", durationMs: durationMs, nativeMediaId: "audiobook-audio-rec")
        )
    }

    private func repository(_ item: Item) -> InMemorySessionRepository {
        InMemorySessionRepository(items: [item.id: item], sessions: [:], interjections: [:])
    }

    func testPlacedMarginsAreWrittenAtTheirTimesAndThePlaceIsLeftAtTheStart() throws {
        let item = audioItem(durationMs: 120_000)
        let repo = repository(item)
        let placed = [
            LiveSessionAlignment.Placed(id: "b", text: "Second", offsetMs: 70_000),
            LiveSessionAlignment.Placed(id: "a", text: "First", offsetMs: 12_500),
            LiveSessionAlignment.Placed(id: "c", text: "   ", offsetMs: 80_000),
            LiveSessionAlignment.Placed(id: "d", text: "Past the end", offsetMs: 500_000)
        ]
        let saved = try LiveSessionMarginPlacer.place(placed, itemId: item.id, repository: repo)
        XCTAssertEqual(saved.map(\.displayText), ["First", "Second", "Past the end"])
        XCTAssertEqual(saved.map(\.anchor.mediaTimeMs), [12_500, 70_000, 119_999])
        let sessions = try repo.loadSessions(itemId: item.id)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.position.mediaTimeMs, 0)
    }

    func testMissingOrNonAudioItemsThrowBeforeWriting() {
        let text = Item(id: "t", title: "Text", mediaType: "text", text: "Hi", externalReference: nil, status: "ready")
        let repo = repository(text)
        XCTAssertThrowsError(try LiveSessionMarginPlacer.place([], itemId: "missing", repository: repo)) {
            XCTAssertEqual($0 as? LiveSessionMarginPlacer.Failure, .itemNotFound)
        }
        XCTAssertThrowsError(try LiveSessionMarginPlacer.place([], itemId: "t", repository: repo)) {
            XCTAssertEqual($0 as? LiveSessionMarginPlacer.Failure, .notAudio)
        }
    }
}
