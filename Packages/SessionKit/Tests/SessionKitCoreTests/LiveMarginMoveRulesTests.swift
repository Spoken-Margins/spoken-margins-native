import Foundation
import XCTest
@testable import SessionKit

/// #4233 Design 6a: which live-session Margins can move, where each lands on the chosen item, the picker's two sections,
/// the empty-session rule and the dialog's words. A place comes only from a saved hint or a player run of that item, on an
/// item with a media clock, inside its duration; never from the resume point.
final class LiveMarginMoveRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func episode(id: String = "ep", durationMs: Int? = 600_000, deleted: Bool = false) -> Item {
        var item = Item(
            id: id, title: "Episode \(id)", mediaType: "podcast", text: nil, externalReference: "https://example.com/\(id).mp3",
            status: "ready", externalReferenceType: "podcast",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/\(id).mp3", durationMs: durationMs, nativeMediaId: "\(id)-audio"))
        if deleted { item.deletedAt = at(0) }
        return item
    }

    private func article(id: String = "art") -> Item {
        Item(id: id, title: "Article", mediaType: "article", text: "Some words. More words.", externalReference: nil, status: "ready")
    }

    private func session(for item: Item, target: TargetType = .transcriptBackedMedia, resumeMs: Int = 421_000) -> Session {
        Session(
            id: "s-\(item.id)", itemId: item.id, createdAt: at(-1_000), updatedAt: at(-1_000), status: "in_progress", phase: .itemPlayback,
            currentTargetType: target, currentTargetId: target == .itemTextTTS ? item.id : "\(item.id)-audio",
            position: Position(charOffset: 0, mediaTimeMs: resumeMs), completionPercent: 70, playbackRate: 1)
    }

    private func repository(items: [Item], sessions: [Session]) -> InMemorySessionRepository {
        InMemorySessionRepository(
            items: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }),
            sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }),
            interjections: [:])
    }

    private func spoken(_ id: String, at offset: TimeInterval, words: String = "", hint: LiveSessionPlayingThen? = nil) -> LiveSessionMargin {
        var margin = LiveSessionMargin(
            id: id, text: words, markedAt: at(offset), audioPath: "SpokenMargins/interjections/\(id).m4a", durationMs: 3_000, spokenOn: "watch")
        margin.playingThen = hint
        return margin
    }

    private func quick(_ margins: [LiveSessionMargin], title: String = "Quick session") -> LiveSession {
        var session = LiveSession(id: "quick-1", title: title, startedAt: margins.first?.markedAt ?? t0, endedAt: margins.last?.markedAt, isQuick: true)
        for margin in margins { session.add(margin) }
        return session
    }

    // MARK: Movability (Design 2.4)

    func testWhatCanMove() throws {
        var photo = LiveSessionMargin(id: "photo", text: "Page note", markedAt: at(5))
        photo.photo = try XCTUnwrap(LiveSessionPhoto(path: "SpokenMargins/live-photos/quick-1/photo.jpg", widthPx: 10, heightPx: 10, byteCount: 10))
        let cases: [(LiveSessionMargin, LiveMarginMove.Unmovable?)] = [
            (spoken("untranscribed", at: 1), nil),
            (spoken("transcribed", at: 2, words: "Words"), nil),
            (LiveSessionMargin(id: "written", text: "Typed", markedAt: at(3)), nil),
            (LiveSessionMargin(id: "blank-mark", text: "", markedAt: at(4), isBlindMark: true), .isMark),
            (LiveSessionMargin(id: "written-on-mark", text: "Said later", markedAt: at(4.5), isBlindMark: true), nil),
            (photo, .hasPhoto),
        ]
        let session = quick(cases.map(\.0))
        for (margin, expected) in cases {
            XCTAssertEqual(LiveMarginMove.movability(margin: margin, in: session), expected, margin.id)
        }
        XCTAssertEqual(LiveMarginMove.Unmovable.hasPhoto.reason, "Margins with a page photo stay in the session.")
        XCTAssertEqual(LiveMarginMove.Unmovable.isMark.reason, "A Mark has no words or recording to move.")
        XCTAssertEqual(LiveMarginMove.movableMargins(in: session).map(\.id), ["untranscribed", "transcribed", "written", "written-on-mark"])
        XCTAssertTrue(LiveMarginMove.offersMove(in: session))

        var saved = session
        saved.savedItemId = "notes"
        XCTAssertEqual(LiveMarginMove.movability(margin: cases[0].0, in: saved), .savedSession)
        XCTAssertNil(LiveMarginMove.Unmovable.savedSession.reason, "a saved session shows nothing")
        XCTAssertFalse(LiveMarginMove.offersMove(in: saved))
        XCTAssertFalse(LiveMarginMove.offersMove(in: quick([cases[3].0, photo])), "only Marks and photos: no Move")
    }

    // MARK: The empty-session rule (Design 2.7)

    func testOnlyAnUnrenamedQuickSessionEmptiedByTheMoveGoes() {
        let a = spoken("a", at: 1), b = spoken("b", at: 2)
        XCTAssertTrue(LiveMarginMove.removesSession(quick([a, b]), movingIds: ["a", "b"]))
        XCTAssertFalse(LiveMarginMove.removesSession(quick([a, b]), movingIds: ["a"]), "one left behind")
        XCTAssertFalse(LiveMarginMove.removesSession(quick([a, b], title: "Book club"), movingIds: ["a", "b"]), "renamed")
        var named = LiveSession(id: "named", kind: .meeting, title: "", startedAt: at(0), endedAt: at(10))
        named.add(a)
        XCTAssertFalse(LiveMarginMove.removesSession(named, movingIds: ["a"]), "a named session stays")
        var saved = quick([a])
        saved.savedItemId = "notes"
        XCTAssertFalse(LiveMarginMove.removesSession(saved, movingIds: ["a"]))
    }

    // MARK: Placement (Design 2.9.2)

    func testWhereEachMarginLands() throws {
        let ep = episode(), other = episode(id: "other"), art = article(), noLength = episode(id: "nolen", durationMs: nil)
        let repo = repository(
            items: [ep, other, art, noLength],
            sessions: [session(for: ep), session(for: other), session(for: art, target: .itemTextTTS), session(for: noLength)])
        let run = LiveSessionFiling.PlayerRun(itemId: "ep", startedAt: at(100), endedAt: at(200), startPositionMs: 50_000, rate: 1)
        struct Row { var name: String; var margin: LiveSessionMargin; var item: String; var runs: [LiveSessionFiling.PlayerRun]; var position: Int?; var source: String? }
        let rows = [
            Row(name: "hint for the item", margin: spoken("h", at: 1, hint: .init(itemId: "ep", positionMs: 64_000, source: .playerRun)),
                item: "ep", runs: [], position: 64_000, source: "savedRun"),
            Row(name: "Watch target with a position", margin: spoken("w", at: 1, hint: .init(itemId: "ep", positionMs: 9_000, source: .watchTarget)),
                item: "ep", runs: [], position: 9_000, source: "watchTarget"),
            Row(name: "Watch target without a position", margin: spoken("wn", at: 1, hint: .init(itemId: "ep", positionMs: nil, source: .watchTarget)),
                item: "ep", runs: [], position: nil, source: nil),
            Row(name: "a run of the item held its time", margin: spoken("r", at: 130), item: "ep", runs: [run], position: 80_000, source: "savedRun"),
            Row(name: "a run of another item", margin: spoken("ro", at: 130), item: "other", runs: [run], position: nil, source: nil),
            Row(name: "hint names another item", margin: spoken("x", at: 1, hint: .init(itemId: "other", positionMs: 5_000, source: .playerRun)),
                item: "ep", runs: [], position: nil, source: nil),
            Row(name: "an article has no media clock", margin: spoken("a", at: 1, hint: .init(itemId: "art", positionMs: 5_000, source: .playerRun)),
                item: "art", runs: [], position: nil, source: nil),
            Row(name: "past the end", margin: spoken("p", at: 1, hint: .init(itemId: "ep", positionMs: 600_000, source: .playerRun)),
                item: "ep", runs: [], position: nil, source: nil),
            Row(name: "no known length", margin: spoken("n", at: 1, hint: .init(itemId: "nolen", positionMs: 5_000, source: .playerRun)),
                item: "nolen", runs: [], position: nil, source: nil),
            Row(name: "nothing saved: never the resume point", margin: spoken("none", at: 1), item: "ep", runs: [], position: nil, source: nil),
        ]
        for row in rows {
            let plan = try LiveMarginMove.plan(margins: [row.margin], session: quick([row.margin]), itemId: row.item, runs: row.runs, repository: repo)
            XCTAssertEqual(plan.margins.first?.positionMs, row.position, row.name)
            XCTAssertEqual(plan.margins.first?.placeSource, row.source, row.name)
        }
    }

    func testThePlanCountsAndLeavesOutWhatCannotMove() throws {
        let ep = episode()
        let repo = repository(items: [ep], sessions: [session(for: ep)])
        let placed = spoken("p", at: 1, hint: .init(itemId: "ep", positionMs: 1_000, source: .playerRun))
        let unplaced = spoken("u", at: 2)
        let mark = LiveSessionMargin(id: "m", text: "", markedAt: at(3), isBlindMark: true)
        let elsewhere = spoken("gone", at: 4)
        let live = quick([placed, unplaced, mark])
        let plan = try LiveMarginMove.plan(margins: [placed, unplaced, mark, elsewhere], session: live, itemId: "ep", repository: repo)
        XCTAssertEqual(plan.margins.map(\.margin.id), ["p", "u"])
        XCTAssertEqual(plan.placedCount, 1)
        XCTAssertEqual(plan.unplacedCount, 1)
        XCTAssertFalse(plan.removesSession, "the Mark stays, so the session stays")
        XCTAssertEqual(plan.targetSessionId, "s-ep")

        XCTAssertThrowsError(try LiveMarginMove.plan(margins: [mark, elsewhere], session: live, itemId: "ep", repository: repo)) {
            XCTAssertEqual($0 as? LiveMarginMove.Failure, .nothingToMove)
        }
        XCTAssertThrowsError(try LiveMarginMove.plan(margins: [placed], session: live, itemId: "missing", repository: repo)) {
            XCTAssertEqual($0 as? LiveMarginMove.Failure, .itemNotFound)
        }
        let unstarted = repository(items: [ep], sessions: [])
        XCTAssertThrowsError(try LiveMarginMove.plan(margins: [placed], session: live, itemId: "ep", repository: unstarted)) {
            XCTAssertEqual($0 as? LiveMarginMove.Failure, .noSession)
        }
    }

    // MARK: Suggestions (Design 2.5)

    func testSuggestionsPutWhatWasPlayingFirstNewestMarginFirst() {
        let choices = ["a", "b", "c", "d"].map { StoredSessionMargin.ItemChoice(id: $0, title: $0.uppercased()) }
        let margins = [
            spoken("1", at: 1, hint: .init(itemId: "c", positionMs: 1, source: .playerRun)),
            spoken("2", at: 2, hint: .init(itemId: "b", positionMs: nil, source: .watchTarget)),
            spoken("3", at: 3, hint: .init(itemId: "gone", positionMs: 1, source: .playerRun)),
            spoken("4", at: 4, hint: .init(itemId: "c", positionMs: 2, source: .playerRun)),
            spoken("5", at: 5),
        ]
        let (playing, recent) = LiveMarginMove.suggestions(margins: margins, choices: choices)
        XCTAssertEqual(playing.map(\.id), ["c", "b"], "newest Margin naming each; an item that's gone is left out")
        XCTAssertEqual(recent.map(\.id), ["a", "d"], "the rest in the given order")

        let none = LiveMarginMove.suggestions(margins: [spoken("x", at: 1)], choices: choices)
        XCTAssertTrue(none.playingThen.isEmpty, "Margins filed before playingThen have no section")
        XCTAssertEqual(none.recent.count, 4)
    }

    /// Design 5, `long-source`: the picker's list over 2,000 started items stays quick.
    func testTwoThousandChoicesAreAllOffered() {
        let items = (0..<2_000).map { episode(id: "item-\($0)") }
        let sessions = items.enumerated().map { index, item in
            var started = session(for: item)
            started.updatedAt = at(Double(index))
            return started
        }
        let margins = (0..<50).map { spoken("m\($0)", at: Double($0), hint: .init(itemId: "item-\($0 * 7)", positionMs: 1, source: .playerRun)) }
        let choices = StoredSessionMargin.itemChoices(items: items, sessions: sessions, startedOnly: true)
        let (playing, recent) = LiveMarginMove.suggestions(margins: margins, choices: choices)
        XCTAssertEqual(playing.count + recent.count, 2_000)
        XCTAssertEqual(choices.first?.id, "item-1999", "newest listening first")
    }

    // MARK: Words (Design 2.6, 2.7)

    func testTheDialogSaysWhatWillHappen() {
        typealias W = LiveMarginMove.Wording
        XCTAssertEqual(W.dialogTitle(count: 1, title: "Ep"), "Move this Margin to “Ep”?")
        XCTAssertEqual(W.dialogTitle(count: 3, title: "Ep"), "Move 3 Margins to “Ep”?")
        XCTAssertEqual(W.dialogMessage(placed: 1, unplaced: 0, title: "Ep"), "It will sit where “Ep” was playing when you made it.")
        XCTAssertEqual(W.dialogMessage(placed: 0, unplaced: 1, title: "Ep"),
                       "No playback place was saved with this Margin, so it will be on the item without a place.")
        XCTAssertEqual(W.dialogMessage(placed: 3, unplaced: 0, title: "Ep"), "They'll sit where “Ep” was playing when you made them.")
        XCTAssertEqual(W.dialogMessage(placed: 0, unplaced: 3, title: "Ep"),
                       "No playback place was saved with them, so they'll be on the item without a place.")
        XCTAssertEqual(W.dialogMessage(placed: 1, unplaced: 2, title: "Ep"),
                       "1 will sit where it was playing when you made it. 2 had no playback place saved and will be on the item without a place.")
        XCTAssertEqual(W.dialogMessage(placed: 2, unplaced: 1, title: "Ep"),
                       "2 will sit where it was playing when you made them. 1 had no playback place saved and will be on the item without a place.")
        XCTAssertEqual(W.confirmButton(count: 1), "Move Margin")
        XCTAssertEqual(W.confirmButton(count: 3), "Move 3 Margins")
        XCTAssertEqual(W.moved(count: 1, title: "Ep"), "Moved the Margin to “Ep”.")
        XCTAssertEqual(W.moved(count: 2, title: "Ep"), "Moved 2 Margins to “Ep”.")
        XCTAssertEqual(W.movingLine(count: 1), "Moving 1 Margin")
        XCTAssertEqual(W.movingLine(count: 3), "Moving 3 Margins")
        XCTAssertEqual(W.noHits("  tide "), "No started item matches “tide”.")
        XCTAssertEqual(LiveMarginMove.UndoRefusal.changedOnItem(title: "Ep").message, "Couldn't put the Margins back. They've changed on “Ep”.")
    }
}
