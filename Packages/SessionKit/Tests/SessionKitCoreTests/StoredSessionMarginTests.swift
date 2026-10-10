import Foundation
import XCTest
@testable import SessionKit

/// #1073: the Shortcuts "Add Margin" action given an item that isn't playing writes a Margin on that item's
/// saved session, at its saved place, and leaves whatever is playing alone.
final class StoredSessionMarginTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence", "browser_session_handoff"],
            "playback": ["realtime_tts", "prerendered_audio", "native_media"],
            "timeline": ["transcript_segments", "media_time", "chapter_timing"],
            "interjection": ["record_audio", "delegate_interjection_to_canonical_runtime"]
        ]
    )

    private let playingText = "Alpha one. Alpha two. Alpha three."
    private let savedText = "First sentence. Second sentence. Third sentence."
    private let savedOffset = 16 // the start of "Second sentence."

    private var playingItem: Item {
        Item(id: "item-playing", title: "Playing", mediaType: "text", text: playingText, externalReference: nil, status: "ready")
    }

    private var savedItem: Item {
        Item(id: "item-saved", title: "Saved", mediaType: "text", text: savedText, externalReference: nil, status: "ready")
    }

    private func savedSession(
        id: String = "session-saved", status: String = "in_progress", phase: SessionPhase = .itemPlayback,
        offset: Int? = nil, percent: Int = 33, updatedAt: Date? = nil
    ) -> Session {
        Session(
            id: id, itemId: savedItem.id, createdAt: updatedAt, updatedAt: updatedAt, status: status, phase: phase,
            currentTargetType: .itemTextTTS, currentTargetId: savedItem.id,
            position: Position(charOffset: offset ?? savedOffset), completionPercent: percent, playbackRate: 1
        )
    }

    /// The player behind the item that is playing. It counts what it is asked to do and reports a place of its own
    /// (3), which the other item's Margin must never pick up.
    private final class LivePlayer: AudioPlaybackClient {
        var plays = 0
        var pauses = 0
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { plays += 1 }
        func pause() throws { pauses += 1 }
        func currentCharOffset() -> Int? { 3 }
    }

    private func repository(_ sessions: [Session], items: [Item]? = nil) -> InMemorySessionRepository {
        let items = items ?? [playingItem, savedItem]
        return InMemorySessionRepository(
            items: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }),
            sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }),
            interjections: [:]
        )
    }

    func testWritesOnTheSavedSessionAtItsSavedPlaceWhileAnotherItemPlays() throws {
        let repository = repository([savedSession()])
        let player = LivePlayer()
        let live = SessionEngine(profile: profile, repository: repository, audio: player)
        let playing = try live.startSession(itemId: playingItem.id)
        let playsBefore = player.plays
        let pausesBefore = player.pauses
        let playingSessionId = try XCTUnwrap(playing.sessionId)
        let playingSessionBefore = try XCTUnwrap(repository.loadSession(id: playingSessionId))

        let saved = try StoredSessionMargin.addWritten(text: "  Check the second claim.  ", itemId: savedItem.id, repository: repository)

        let margin = saved.interjection
        XCTAssertEqual(saved.itemTitle, "Saved")
        XCTAssertEqual(margin.itemId, savedItem.id)
        XCTAssertEqual(margin.sessionId, "session-saved")
        XCTAssertEqual(margin.captureKind, .written)
        XCTAssertEqual(margin.displayText, "Check the second claim.")
        XCTAssertEqual(margin.transcript, "Check the second claim.")
        XCTAssertEqual(margin.status, "active")
        XCTAssertEqual(margin.targetType, .item)
        XCTAssertEqual(margin.targetId, savedItem.id)
        XCTAssertEqual(margin.anchor.anchorType, .text)
        XCTAssertEqual(margin.anchor.startChar, savedOffset, "the saved place, not the playing item's 3")
        XCTAssertTrue(margin.anchor.anchorBefore.contains("First sentence."))
        XCTAssertTrue(margin.anchor.anchorAfter.contains("Second sentence."))
        XCTAssertEqual(try repository.loadInterjections(sessionId: "session-saved"), [margin])

        // The item that is playing was not touched.
        XCTAssertEqual(player.plays, playsBefore)
        XCTAssertEqual(player.pauses, pausesBefore)
        XCTAssertEqual(live.snapshot.status, .playing)
        XCTAssertEqual(live.snapshot.sessionId, playingSessionId)
        XCTAssertEqual(try repository.loadSession(id: playingSessionId), playingSessionBefore)
        XCTAssertEqual(try repository.loadInterjections(sessionId: playingSessionId), [])
    }

    func testTheSavedSessionStaysWhereTheListenerLeftIt() throws {
        let before = savedSession()
        let repository = repository([before])

        _ = try StoredSessionMargin.addWritten(text: "A note.", itemId: savedItem.id, repository: repository)

        let after = try XCTUnwrap(repository.loadSession(id: before.id))
        XCTAssertEqual(after.position, before.position)
        XCTAssertEqual(after.completionPercent, before.completionPercent)
        XCTAssertEqual(after.phase, before.phase)
        XCTAssertEqual(after.status, before.status)
        XCTAssertEqual(after.currentTargetType, before.currentTargetType)
        XCTAssertEqual(after.currentTargetId, before.currentTargetId)
        XCTAssertEqual(repository.sessions.count, 1, "no session is created")
    }

    func testTheSessionIsNotPulledAheadOfTheOneLastListenedTo() throws {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let repository = repository([savedSession(updatedAt: stamp)])
        let live = SessionEngine(profile: profile, repository: repository, audio: LivePlayer())
        _ = try live.startSession(itemId: playingItem.id)
        let playingSessionId = try XCTUnwrap(live.snapshot.sessionId)

        _ = try StoredSessionMargin.addWritten(text: "Later.", itemId: savedItem.id, repository: repository)

        XCTAssertEqual(try repository.loadSession(id: "session-saved")?.updatedAt, stamp)
        let newest = repository.sessions.values.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
        XCTAssertEqual(newest?.id, playingSessionId, "launch restore still picks the item that was playing")
    }

    func testAnItemWithNoSessionThrowsAndCreatesNothing() {
        let repository = repository([])

        XCTAssertThrowsError(try StoredSessionMargin.addWritten(text: "Orphan.", itemId: savedItem.id, repository: repository)) {
            XCTAssertEqual($0 as? StoredSessionMargin.Failure, .noSession)
        }
        XCTAssertTrue(repository.sessions.isEmpty)
        XCTAssertTrue(repository.interjections.isEmpty)
    }

    func testOnlyAnAbandonedSessionCountsAsNoSession() {
        let repository = repository([savedSession(status: "abandoned", phase: .abandoned)])

        XCTAssertThrowsError(try StoredSessionMargin.addWritten(text: "Orphan.", itemId: savedItem.id, repository: repository)) {
            XCTAssertEqual($0 as? StoredSessionMargin.Failure, .noSession)
        }
        XCTAssertTrue(repository.interjections.isEmpty)
    }

    func testEmptyTextThrowsBeforeAnythingIsRead() {
        let repository = repository([savedSession()])

        for text in ["", "   ", " \n\t "] {
            XCTAssertThrowsError(try StoredSessionMargin.addWritten(text: text, itemId: savedItem.id, repository: repository)) {
                XCTAssertEqual($0 as? StoredSessionMargin.Failure, .emptyText)
            }
        }
        XCTAssertTrue(repository.interjections.isEmpty)
    }

    func testAnItemThatIsNotInTheLibraryThrows() {
        let repository = repository([savedSession()])

        XCTAssertThrowsError(try StoredSessionMargin.addWritten(text: "Note.", itemId: "item-unknown", repository: repository)) {
            XCTAssertEqual($0 as? StoredSessionMargin.Failure, .itemNotFound)
        }
        XCTAssertTrue(repository.interjections.isEmpty)
    }

    func testAnItemInRecentlyDeletedThrows() {
        var deleted = savedItem
        deleted.deletedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let repository = repository([savedSession()], items: [deleted])

        XCTAssertThrowsError(try StoredSessionMargin.addWritten(text: "Note.", itemId: deleted.id, repository: repository)) {
            XCTAssertEqual($0 as? StoredSessionMargin.Failure, .itemNotFound)
        }
        XCTAssertTrue(repository.interjections.isEmpty)
    }

    func testAPodcastTakesTheMarginAtItsSavedTimeNotTheClockOfWhatIsPlaying() throws {
        let episode = Item(
            id: "item-episode", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: "https://example.com/episode", status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 3_600_000)
        )
        let session = Session(
            id: "session-episode", itemId: episode.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: episode.id,
            position: Position(charOffset: 0, mediaTimeMs: 600_000), completionPercent: 16, playbackRate: 1
        )
        let repository = repository([session], items: [playingItem, episode])
        let player = LivePlayer()
        let live = SessionEngine(profile: profile, repository: repository, audio: player)
        _ = try live.startSession(itemId: playingItem.id)

        let saved = try StoredSessionMargin.addWritten(text: "Check the claim at ten minutes.", itemId: episode.id, repository: repository)

        XCTAssertEqual(saved.interjection.sessionId, "session-episode")
        XCTAssertEqual(saved.interjection.anchor.mediaTimeMs, 600_000)
        XCTAssertEqual(saved.interjection.roughPercent, 16)
        XCTAssertEqual(try repository.loadSession(id: "session-episode")?.position.mediaTimeMs, 600_000)
        XCTAssertEqual(live.snapshot.status, .playing)
    }

    func testTheMostRecentResumableSessionGetsTheMargin() throws {
        let older = savedSession(id: "session-older", offset: 0, percent: 0, updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = savedSession(id: "session-newer", updatedAt: Date(timeIntervalSince1970: 2_000))
        let abandoned = savedSession(
            id: "session-abandoned", status: "abandoned", phase: .abandoned, updatedAt: Date(timeIntervalSince1970: 3_000)
        )
        let repository = repository([older, newer, abandoned])

        let saved = try StoredSessionMargin.addWritten(text: "Which one?", itemId: savedItem.id, repository: repository)

        XCTAssertEqual(saved.interjection.sessionId, "session-newer")
        XCTAssertEqual(saved.interjection.anchor.startChar, savedOffset)
        XCTAssertEqual(try repository.loadInterjections(sessionId: "session-older"), [])
        XCTAssertEqual(try repository.loadInterjections(sessionId: "session-abandoned"), [])
    }

    func testAFinishedItemTakesARecapMarginAtItsEnd() throws {
        let finished = savedSession(status: "finished", phase: .finished, offset: savedText.count, percent: 100)
        let repository = repository([finished])

        let saved = try StoredSessionMargin.addWritten(text: "Recap.", itemId: savedItem.id, repository: repository)

        XCTAssertEqual(saved.interjection.anchor.startChar, savedText.count)
        XCTAssertEqual(saved.interjection.roughPercent, 100)
        let after = try XCTUnwrap(repository.loadSession(id: finished.id))
        XCTAssertEqual(after.phase, .finished)
        XCTAssertEqual(after.status, "finished")
        XCTAssertEqual(after.position.charOffset, savedText.count)
    }

    func testTwoMarginsInARowBothSave() throws {
        let repository = repository([savedSession()])

        let first = try StoredSessionMargin.addWritten(text: "One.", itemId: savedItem.id, repository: repository)
        let second = try StoredSessionMargin.addWritten(text: "Two.", itemId: savedItem.id, repository: repository)

        XCTAssertNotEqual(first.interjection.id, second.interjection.id)
        XCTAssertEqual(try repository.loadInterjections(sessionId: "session-saved").count, 2)
    }

    // MARK: - The items a shortcut offers

    private func item(_ id: String, _ title: String, deleted: Bool = false) -> Item {
        Item(id: id, title: title, mediaType: "text", text: "Text.", externalReference: nil, status: "ready",
             deletedAt: deleted ? Date(timeIntervalSince1970: 1_000) : nil)
    }

    private func session(_ itemId: String, updated: Double, status: String = "in_progress", phase: SessionPhase = .itemPlayback) -> Session {
        Session(
            id: "s-\(itemId)-\(Int(updated))", itemId: itemId, createdAt: Date(timeIntervalSince1970: updated),
            updatedAt: Date(timeIntervalSince1970: updated), status: status, phase: phase,
            currentTargetType: .itemTextTTS, currentTargetId: itemId, position: Position(), completionPercent: 10, playbackRate: 1
        )
    }

    func testChoicesListStartedItemsMostRecentFirstAndSkipDeletedOnes() {
        let items = [item("a", "Alpha"), item("b", "Bravo"), item("c", "Charlie"), item("d", "Delta", deleted: true), item("e", "Echo")]
        let sessions = [
            session("a", updated: 100), session("b", updated: 300), session("b", updated: 50),
            session("c", updated: 200, status: "abandoned", phase: .abandoned), session("d", updated: 400),
        ]

        XCTAssertEqual(
            StoredSessionMargin.itemChoices(items: items, sessions: sessions, startedOnly: true).map(\.id), ["b", "a"],
            "Charlie has only an abandoned session, Delta is deleted and Echo was never started"
        )
        XCTAssertEqual(
            StoredSessionMargin.itemChoices(items: items, sessions: sessions, startedOnly: false).map(\.id), ["b", "c", "a", "e"],
            "a saved shortcut still finds the abandoned and the never-started item; Delta stays out"
        )
    }

    func testChoicesMatchTitlesIgnoringCaseAndAccents() {
        let items = [item("a", "Café culture"), item("b", "Cafe society"), item("c", "Tea")]
        let sessions = items.map { session($0.id, updated: 10) }

        XCTAssertEqual(StoredSessionMargin.itemChoices(items: items, sessions: sessions, startedOnly: true, matching: "CAFE").map(\.id), ["b", "a"])
        XCTAssertEqual(StoredSessionMargin.itemChoices(items: items, sessions: sessions, startedOnly: true, matching: "  ").count, 3)
        XCTAssertEqual(StoredSessionMargin.itemChoices(items: items, sessions: sessions, startedOnly: true, matching: "zzz"), [])
    }
}
