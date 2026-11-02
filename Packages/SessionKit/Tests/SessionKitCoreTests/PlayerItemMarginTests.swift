import Foundation
import XCTest
@testable import SessionKit

/// #2542: a Watch Margin taken while our player played an episode lands on that episode at the time it was taken, and the
/// episode still resumes where the listener left it.
final class PlayerItemMarginTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_000)
    private let taken = Date(timeIntervalSince1970: 5_000)

    private var episode: Item {
        Item(
            id: "episode", title: "Episode", mediaType: "podcast", text: nil,
            externalReference: "https://example.com/e.mp3", status: "ready", externalReferenceType: "podcast",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/e.mp3", durationMs: 600_000, nativeMediaId: "episode-audio")
        )
    }

    private func session(
        id: String = "session-episode", status: String = "in_progress", phase: SessionPhase = .itemPlayback,
        target: TargetType = .transcriptBackedMedia, updatedAt: Date? = nil, resumeMs: Int = 421_000, percent: Int = 70
    ) -> Session {
        Session(
            id: id, itemId: "episode", createdAt: updatedAt ?? stamp, updatedAt: updatedAt ?? stamp, status: status, phase: phase,
            currentTargetType: target, currentTargetId: "episode-audio",
            position: Position(charOffset: 0, mediaTimeMs: resumeMs), completionPercent: percent, playbackRate: 1
        )
    }

    private func repository(_ sessions: [Session], items: [Item]? = nil) -> InMemorySessionRepository {
        let items = items ?? [episode]
        return InMemorySessionRepository(
            items: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }),
            sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }),
            interjections: [:]
        )
    }

    func testTheMarginLandsOnTheEpisodeAtTheTimeItWasTaken() throws {
        let repo = repository([session()])

        let saved = try PlayerItemMargin.placeSpoken(
            audioPath: "LiveSessions/m1.m4a", atMediaTimeMs: 64_000, markedAt: taken, itemId: "episode", repository: repo
        )

        XCTAssertEqual(saved.itemId, "episode")
        XCTAssertEqual(saved.sessionId, "session-episode")
        XCTAssertEqual(saved.anchor.mediaTimeMs, 64_000, "the time it was taken, not the resume point 421 s")
        XCTAssertEqual(saved.audioPath, "LiveSessions/m1.m4a")
        XCTAssertEqual(saved.createdAt, taken, "dated when it was spoken, not when it was filed")
        XCTAssertEqual(saved.transcriptionStatus, "pending", "the app's own Margin transcription picks it up")
        XCTAssertEqual(try repo.loadInterjections(sessionId: "session-episode"), [saved])
    }

    func testTheEpisodeResumesWhereItWasLeft() throws {
        let before = session()
        let repo = repository([before])

        _ = try PlayerItemMargin.placeSpoken(
            audioPath: "LiveSessions/m1.m4a", atMediaTimeMs: 64_000, markedAt: taken, itemId: "episode", repository: repo
        )

        XCTAssertEqual(try repo.loadSession(id: before.id), before, "position, percent, phase, status and updatedAt are all as they were")
        XCTAssertEqual(repo.sessions.count, 1, "no sibling session is made")
    }

    func testTheSessionIsNotPulledAheadOfTheOneLastListenedTo() throws {
        let other = Session(
            id: "session-other", itemId: "other", createdAt: stamp, updatedAt: Date(timeIntervalSince1970: 4_000),
            status: "in_progress", phase: .itemPlayback, currentTargetType: .transcriptBackedMedia, currentTargetId: "other-audio",
            position: Position(charOffset: 0, mediaTimeMs: 1_000), completionPercent: 1, playbackRate: 1
        )
        let otherItem = Item(id: "other", title: "Other", mediaType: "podcast", text: nil, externalReference: nil, status: "ready")
        let repo = repository([session(), other], items: [episode, otherItem])

        _ = try PlayerItemMargin.placeSpoken(
            audioPath: "m.m4a", atMediaTimeMs: 10_000, markedAt: taken, itemId: "episode", repository: repo
        )

        let newest = repo.sessions.values.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
        XCTAssertEqual(newest?.id, "session-other")
    }

    func testAFinishedEpisodeStaysFinished() throws {
        let finished = session(status: "finished", phase: .finished, resumeMs: 599_000, percent: 100)
        let repo = repository([finished])

        let saved = try PlayerItemMargin.placeSpoken(
            audioPath: "m.m4a", atMediaTimeMs: 30_000, markedAt: taken, itemId: "episode", repository: repo
        )

        XCTAssertEqual(saved.anchor.mediaTimeMs, 30_000)
        XCTAssertEqual(try repo.loadSession(id: finished.id), finished)
    }

    func testTimesOutsideTheEpisodeAreClamped() throws {
        let repo = repository([session()])
        let late = try PlayerItemMargin.placeSpoken(
            audioPath: "late.m4a", atMediaTimeMs: 900_000, markedAt: taken, itemId: "episode", repository: repo
        )
        let early = try PlayerItemMargin.placeSpoken(
            audioPath: "early.m4a", atMediaTimeMs: -5, markedAt: taken, itemId: "episode", repository: repo
        )
        XCTAssertEqual(late.anchor.mediaTimeMs, 599_999)
        XCTAssertEqual(early.anchor.mediaTimeMs, 0)
        XCTAssertNotEqual(late.id, early.id)
    }

    func testEveryCaseThatCannotTakeItThrowsAndLeavesTheStoreAlone() {
        struct Row { var name: String; var repo: InMemorySessionRepository; var audio: String?; var expected: PlayerItemMargin.Failure }
        var deleted = episode
        deleted.deletedAt = taken
        let rows = [
            Row(name: "no such item", repo: repository([], items: []), audio: "m.m4a", expected: .itemNotFound),
            Row(name: "deleted item", repo: repository([session()], items: [deleted]), audio: "m.m4a", expected: .itemNotFound),
            Row(name: "never started", repo: repository([]), audio: "m.m4a", expected: .noSession),
            Row(name: "abandoned only", repo: repository([session(status: "abandoned", phase: .abandoned)]), audio: "m.m4a", expected: .noSession),
            Row(name: "text narration", repo: repository([session(target: .itemTextTTS)]), audio: "m.m4a", expected: .unsupportedTarget),
            Row(name: "a Mark has no recording", repo: repository([session()]), audio: nil, expected: .noRecording),
            Row(name: "empty recording path", repo: repository([session()]), audio: "", expected: .noRecording)
        ]
        for row in rows {
            let sessionsBefore = row.repo.sessions
            XCTAssertThrowsError(
                try PlayerItemMargin.placeSpoken(audioPath: row.audio, atMediaTimeMs: 1_000, markedAt: taken, itemId: "episode", repository: row.repo),
                row.name
            ) { XCTAssertEqual($0 as? PlayerItemMargin.Failure, row.expected, row.name) }
            XCTAssertEqual(row.repo.sessions, sessionsBefore, row.name)
            XCTAssertTrue(row.repo.interjections.isEmpty, row.name)
        }
    }

    func testTwoMarginsInARowGetTheirOwnIds() throws {
        let repo = repository([session()])
        let first = try PlayerItemMargin.placeSpoken(audioPath: "a.m4a", atMediaTimeMs: 10_000, markedAt: taken, itemId: "episode", repository: repo)
        let second = try PlayerItemMargin.placeSpoken(audioPath: "b.m4a", atMediaTimeMs: 20_000, markedAt: taken, itemId: "episode", repository: repo)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try repo.loadInterjections(sessionId: "session-episode").count, 2)
    }

    func testARetryOfTheSameRecordingReturnsTheMarginAlreadyThere() throws {
        let repo = repository([session()])
        let first = try PlayerItemMargin.placeSpoken(audioPath: "a.m4a", atMediaTimeMs: 10_000, markedAt: taken, itemId: "episode", repository: repo)
        let again = try PlayerItemMargin.placeSpoken(audioPath: "a.m4a", atMediaTimeMs: 10_000, markedAt: taken, itemId: "episode", repository: repo)
        XCTAssertEqual(again, first)
        XCTAssertEqual(try repo.loadInterjections(sessionId: "session-episode").count, 1, "no second copy")
    }
}
