import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4340 PR 3: a Paper note answer written at a chosen place on a paper, through the engine and a real temporary
/// SQLite store. The answer is an ordinary written Margin; only its place and its role differ from a captured one.
final class PaperNoteAnswerEngineTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        for path in paths {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        paths = []
        super.tearDown()
    }

    /// A clock that moves on every read, so a Margin written twice would show two creation times.
    private final class Clock: @unchecked Sendable {
        private var tick = 0
        func now() -> Date { tick += 1; return Date(timeIntervalSince1970: Double(1_000 + tick)) }
    }

    private let paragraphs = [
        "Abstract. We study sleep. Our aim is plain.",
        "Methods. We ran ten trials. Each lasted a week.",
        "Journal of Sleep",
        "Results. Sleep fell by half. The effect held.",
        "Discussion. This fits earlier work. It does not settle the cause.",
        "Conclusion. We end here. Nothing more."
    ]
    private var text: String { paragraphs.joined(separator: "\n\n") }

    private func offset(of needle: String) -> Int {
        let range = text.range(of: needle)!
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    /// Five pages: the abstract, the methods, a page whose first line is a running header, the discussion and the
    /// conclusion. The header is page index 2's first segment and is never an answer's place.
    private func makeDocument() -> StructuredDocument {
        func segment(_ id: String, _ role: StructuredDocument.Role, _ paragraph: String, page: Int) -> StructuredDocument.Segment {
            StructuredDocument.Segment(
                id: id, role: role,
                range: .init(start: offset(of: paragraph), length: paragraph.count),
                pageIndex: page
            )
        }
        return StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 5, textSHA256: nil),
            text: text,
            segments: [
                segment("s0", .abstract, paragraphs[0], page: 0),
                segment("s1", .body, paragraphs[1], page: 1),
                segment("s2", .pageHeader, paragraphs[2], page: 2),
                segment("s3", .body, paragraphs[3], page: 2),
                segment("s4", .body, paragraphs[4], page: 3),
                segment("s5", .body, paragraphs[5], page: 4)
            ],
            markers: []
        )
    }

    /// The page of the segment that starts at or before `character`: the page the answer is filed under. (The
    /// document's own `pageNumber(atCharacter:)` gives no page when a segment may run over onto the next one.)
    private func page(atCharacter character: Int, in document: StructuredDocument) -> Int? {
        document.segments.sorted { $0.range.start < $1.range.start }
            .last { $0.range.start <= character }?.pageIndex.map { $0 + 1 }
    }

    private func session(
        _ id: String, itemId: String = "paper", status: String = "in_progress", phase: SessionPhase = .itemPlayback,
        at charOffset: Int, percent: Int, updatedAt: Double = 1
    ) -> Session {
        Session(
            id: id, itemId: itemId, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: updatedAt),
            status: status, phase: phase, currentTargetType: .itemTextTTS, currentTargetId: itemId,
            position: Position(charOffset: charOffset), completionPercent: percent, playbackRate: 1
        )
    }

    private struct Rig {
        let store: SQLiteSessionStore
        let engine: SessionEngine
        let path: String
        let item: Item
        let document: StructuredDocument
    }

    private func makeRig(sessions: [Session]) throws -> Rig {
        let path = FileManager.default.temporaryDirectory.appending(path: "paper-note-\(UUID().uuidString).sqlite").path
        paths.append(path)
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "paper", title: "Sleep and memory", mediaType: "text", text: text, externalReference: nil, status: "ready")
        try store.saveItem(item)
        let other = Item(id: "other", title: "Another article", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        try store.saveItem(other)
        for session in sessions { try store.saveSession(session) }
        let clock = Clock()
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "paper-note", displayName: "Paper note", capabilities: [:]),
            repository: store, now: clock.now
        )
        return Rig(store: store, engine: engine, path: path, item: item, document: makeDocument())
    }

    // MARK: The anchor is the capture's anchor

    func testAnAnswerAtAPlaceIsAnchoredExactlyAsACaptureThere() throws {
        let place = offset(of: "We ran ten trials")
        let rig = try makeRig(sessions: [session("s1", at: place, percent: 40)])
        _ = try rig.engine.inspectSession(sessionId: "s1")
        let capture = try rig.engine.beginWrittenInterjection()
        _ = try rig.engine.cancelWrittenInterjection(captureId: capture.id)
        XCTAssertEqual(capture.anchor.startChar, place, "the capture starts where the session was left")

        let answer = try rig.engine.addWrittenInterjection(id: "draft-1", sessionId: "s1", atCharacter: place, text: "Ten trials.")

        XCTAssertEqual(answer.anchor, capture.anchor, "one function builds both")
        XCTAssertEqual(answer.targetType, .item)
        XCTAssertEqual(answer.targetId, "paper")
        XCTAssertEqual(answer.captureKind, .written)
        XCTAssertEqual(answer.status, "active")
        XCTAssertEqual(answer.displayText, "Ten trials.")
        XCTAssertNil(answer.audioPath)
        XCTAssertNil(answer.paperRole)
    }

    func testAnOffsetPastTheEndOrBelowZeroIsHeldToTheText() throws {
        let rig = try makeRig(sessions: [session("s1", at: 0, percent: 0)])
        let past = try rig.engine.addWrittenInterjection(id: "a", sessionId: "s1", atCharacter: text.count + 50, text: "End.")
        let below = try rig.engine.addWrittenInterjection(id: "b", sessionId: "s1", atCharacter: -5, text: "Start.")
        XCTAssertEqual(past.anchor.startChar, text.count)
        XCTAssertEqual(below.anchor.startChar, 0)
    }

    // MARK: The engine's current session and everyone else's

    func testTheCurrentSessionsSnapshotShowsTheNewMarginAtOnce() throws {
        let rig = try makeRig(sessions: [session("s1", at: 0, percent: 10)])
        let before = try rig.engine.inspectSession(sessionId: "s1")
        XCTAssertEqual(before.activeInterjectionCount, 0)

        _ = try rig.engine.addWrittenInterjection(id: "d", sessionId: "s1", atCharacter: offset(of: "Results"), text: "Sleep fell.", paperRole: .keyFinding)

        let after = rig.engine.snapshot
        XCTAssertEqual(after.activeInterjectionCount, 1)
        XCTAssertEqual(after.status, before.status, "writing is not playback")
        XCTAssertEqual(after.progressPercent, before.progressPercent)
        XCTAssertEqual(rig.engine.currentSession?.position, Position(charOffset: 0), "the playhead did not move")
        XCTAssertEqual(try rig.store.loadSession(id: "s1")?.position, Position(charOffset: 0))
    }

    func testAnAnswerOnAnotherSessionLeavesTheCurrentSessionAndPlaybackAlone() throws {
        let paperSession = session("paper-session", at: offset(of: "Results"), percent: 60, updatedAt: 5)
        let otherSession = session("other-session", itemId: "other", at: 5, percent: 30, updatedAt: 9)
        let rig = try makeRig(sessions: [paperSession, otherSession])
        _ = try rig.engine.inspectSession(sessionId: "other-session")
        let snapshotBefore = rig.engine.snapshot
        let currentBefore = rig.engine.currentSession

        let answer = try rig.engine.addWrittenInterjection(
            id: "d", sessionId: "paper-session", atCharacter: offset(of: "Methods"), text: "Ten trials.", paperRole: .purpose
        )

        XCTAssertEqual(rig.engine.snapshot, snapshotBefore, "the playing item's state, clocks and Margin count are untouched")
        XCTAssertEqual(rig.engine.currentSession, currentBefore)
        XCTAssertEqual(try rig.store.loadSession(id: "other-session"), otherSession)
        XCTAssertEqual(try rig.store.loadSession(id: "paper-session"), paperSession, "the session's progress, place and stamp are unchanged")
        XCTAssertEqual(try rig.store.loadInterjections(sessionId: "paper-session").map(\.id), [answer.id])
        XCTAssertEqual(try rig.store.loadInterjections(sessionId: "other-session"), [])
    }

    // MARK: A double tap on Save

    func testTheSameDraftIdWritesOneMargin() throws {
        let rig = try makeRig(sessions: [session("s1", at: 0, percent: 0)])
        let first = try rig.engine.addWrittenInterjection(id: "draft", sessionId: "s1", atCharacter: 10, text: "First words.", paperRole: .purpose)
        let second = try rig.engine.addWrittenInterjection(id: "draft", sessionId: "s1", atCharacter: 99, text: "Changed words.", paperRole: .evidence)

        XCTAssertEqual(second, first, "the second call returns what the first one saved")
        let stored = try rig.store.loadInterjections(sessionId: "s1")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.displayText, "First words.")
        XCTAssertEqual(stored.first?.paperRole, .purpose)
        XCTAssertEqual(stored.first?.createdAt, first.createdAt)
    }

    func testDifferentDraftIdsAreDifferentMargins() throws {
        let rig = try makeRig(sessions: [session("s1", at: 0, percent: 0)])
        _ = try rig.engine.addWrittenInterjection(id: "one", sessionId: "s1", atCharacter: 10, text: "One.", paperRole: .evidence)
        _ = try rig.engine.addWrittenInterjection(id: "two", sessionId: "s1", atCharacter: 10, text: "Two.", paperRole: .evidence)
        XCTAssertEqual(try rig.store.loadInterjections(sessionId: "s1").count, 2)
    }

    // MARK: Nothing is written when the answer cannot be

    func testNothingIsWrittenForEmptyTextAnUnknownSessionOrAnItemWithoutText() throws {
        let rig = try makeRig(sessions: [session("s1", at: 0, percent: 0)])
        for empty in ["", "   ", "\n\t "] {
            XCTAssertThrowsError(try rig.engine.addWrittenInterjection(id: "e", sessionId: "s1", atCharacter: 0, text: empty), "'\(empty)'")
        }
        XCTAssertThrowsError(try rig.engine.addWrittenInterjection(id: "u", sessionId: "missing", atCharacter: 0, text: "Words."))

        try rig.store.saveItem(Item(id: "bare", title: "No text", mediaType: "text", text: nil, externalReference: nil, status: "ready"))
        try rig.store.saveSession(session("bare-session", itemId: "bare", at: 0, percent: 0))
        XCTAssertThrowsError(try rig.engine.addWrittenInterjection(id: "b", sessionId: "bare-session", atCharacter: 0, text: "Words."))

        XCTAssertEqual(try rig.store.loadInterjections(sessionId: "s1"), [])
        XCTAssertEqual(try rig.store.loadInterjections(sessionId: "bare-session"), [])
    }

    // MARK: Roles

    func testARoleIsSetChangedAndTakenOffAndSurvivesARelaunch() throws {
        let rig = try makeRig(sessions: [session("s1", at: 0, percent: 0)])
        let answer = try rig.engine.addWrittenInterjection(id: "d", sessionId: "s1", atCharacter: offset(of: "Results"), text: "Sleep fell.")
        XCTAssertNil(answer.paperRole)

        try rig.engine.setPaperRole(.evidence, interjectionId: answer.id, sessionId: "s1")
        XCTAssertEqual(try rig.store.loadInterjections(sessionId: "s1").first?.paperRole, .evidence)

        try rig.engine.setPaperRole(.keyFinding, interjectionId: answer.id, sessionId: "s1")
        let reopened = try SQLiteSessionStore(path: rig.path)
        let kept = try XCTUnwrap(reopened.loadInterjections(sessionId: "s1").first)
        XCTAssertEqual(kept.paperRole, .keyFinding, "after a relaunch the role is still there")
        XCTAssertEqual(kept.anchor, answer.anchor, "only the role changed")
        XCTAssertEqual(kept.displayText, "Sleep fell.")

        try rig.engine.setPaperRole(nil, interjectionId: answer.id, sessionId: "s1")
        XCTAssertNil(try rig.store.loadInterjections(sessionId: "s1").first?.paperRole)
        XCTAssertEqual(try rig.store.loadInterjections(sessionId: "s1").count, 1, "taking the role off keeps the Margin")
    }

    // MARK: Change answer (#4340 PR 4)

    func testChangeAnswerMovesTheRoleAndKeepsTheOldMargin() throws {
        let rig = try makeRig(sessions: [session("s1", at: 0, percent: 0), session("s2", at: 0, percent: 0, updatedAt: 2)])
        let old = try rig.engine.addWrittenInterjection(id: "a", sessionId: "s1", atCharacter: offset(of: "Abstract"), text: "Aim.", paperRole: .purpose)
        let new = try rig.engine.addWrittenInterjection(id: "b", sessionId: "s2", atCharacter: offset(of: "Results"), text: "Better aim.")

        try rig.engine.changePaperAnswer(.purpose, interjectionId: new.id, sessionId: "s2", replacing: (old.id, "s1"))

        let reopened = try SQLiteSessionStore(path: rig.path)
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "s2").first?.paperRole, .purpose)
        let kept = try XCTUnwrap(reopened.loadInterjections(sessionId: "s1").first)
        XCTAssertNil(kept.paperRole, "the old answer gives up the role")
        XCTAssertEqual(kept.status, "active", "the old Margin stays")
        XCTAssertEqual(kept.displayText, "Aim.")
    }

    func testChangeAnswerLeavesAnOldMarginThatNoLongerHoldsTheRole() throws {
        let rig = try makeRig(sessions: [session("s1", at: 0, percent: 0)])
        let old = try rig.engine.addWrittenInterjection(id: "a", sessionId: "s1", atCharacter: 0, text: "Now evidence.", paperRole: .evidence)
        let new = try rig.engine.addWrittenInterjection(id: "b", sessionId: "s1", atCharacter: offset(of: "Results"), text: "Aim.")

        try rig.engine.changePaperAnswer(.purpose, interjectionId: new.id, sessionId: "s1", replacing: (old.id, "s1"))

        let margins = try rig.store.loadInterjections(sessionId: "s1")
        XCTAssertEqual(margins.first { $0.id == old.id }?.paperRole, .evidence, "a role set elsewhere since is not taken off")
        XCTAssertEqual(margins.first { $0.id == new.id }?.paperRole, .purpose)
    }

    func testChangeAnswerToTheSameMarginOrAGoneOneKeepsTheRole() throws {
        let rig = try makeRig(sessions: [session("s1", at: 0, percent: 0)])
        let answer = try rig.engine.addWrittenInterjection(id: "a", sessionId: "s1", atCharacter: 0, text: "Aim.", paperRole: .purpose)

        try rig.engine.changePaperAnswer(.purpose, interjectionId: answer.id, sessionId: "s1", replacing: (answer.id, "s1"))
        XCTAssertEqual(try rig.store.loadInterjections(sessionId: "s1").first?.paperRole, .purpose)

        try rig.engine.changePaperAnswer(.purpose, interjectionId: answer.id, sessionId: "s1", replacing: ("gone", "missing-session"))
        XCTAssertEqual(try rig.store.loadInterjections(sessionId: "s1").first?.paperRole, .purpose)
    }

    func testChangeAnswerToAMissingMarginWritesNothing() throws {
        let rig = try makeRig(sessions: [session("s1", at: 0, percent: 0)])
        let old = try rig.engine.addWrittenInterjection(id: "a", sessionId: "s1", atCharacter: 0, text: "Aim.", paperRole: .purpose)

        XCTAssertThrowsError(try rig.engine.changePaperAnswer(.purpose, interjectionId: "nope", sessionId: "s1", replacing: (old.id, "s1")))
        XCTAssertEqual(try rig.store.loadInterjections(sessionId: "s1").first?.paperRole, .purpose, "the old answer keeps its role")
    }

    func testSettingARoleOnAMissingMarginOrSessionThrows() throws {
        let rig = try makeRig(sessions: [session("s1", at: 0, percent: 0)])
        XCTAssertThrowsError(try rig.engine.setPaperRole(.purpose, interjectionId: "nope", sessionId: "s1"))
        XCTAssertThrowsError(try rig.engine.setPaperRole(.purpose, interjectionId: "nope", sessionId: "missing"))
    }

    func testAWrittenAnswerAndItsRoleAreWhereItsPageIs() throws {
        let rig = try makeRig(sessions: [session("s1", at: 0, percent: 0)])
        let start = try PaperNotePlace.resolve(item: rig.item, document: rig.document, session: nil, choice: .startOfPage(4))
        _ = try rig.engine.addWrittenInterjection(id: "d", sessionId: "s1", atCharacter: start, text: "Fits earlier work.", paperRole: .evidence)

        let reopened = try SQLiteSessionStore(path: rig.path)
        let kept = try XCTUnwrap(reopened.loadInterjections(sessionId: "s1").first)
        XCTAssertEqual(kept.paperRole, .evidence)
        XCTAssertEqual(page(atCharacter: kept.anchor.startChar, in: rig.document), 4, "it is at its page after a relaunch")
    }

    // MARK: Where an answer sits

    func testStartOfPageFiveIsThatPagesFirstTextSegment() throws {
        let start = try PaperNotePlace.resolve(item: makeRig(sessions: []).item, document: makeDocument(), session: nil, choice: .startOfPage(5))
        XCTAssertEqual(start, offset(of: "Conclusion."))
    }

    func testAPageThatStartsWithARunningHeaderGivesItsFirstRealText() throws {
        let rig = try makeRig(sessions: [])
        let start = try PaperNotePlace.resolve(item: rig.item, document: rig.document, session: nil, choice: .startOfPage(3))
        XCTAssertEqual(start, offset(of: "Results."), "the header 'Journal of Sleep' is not the place")
    }

    func testPageBoundsAndMissingPagesAreRefused() throws {
        let rig = try makeRig(sessions: [])
        for page in [0, -1, 6, 100] {
            XCTAssertThrowsError(
                try PaperNotePlace.resolve(item: rig.item, document: rig.document, session: nil, choice: .startOfPage(page)), "page \(page)"
            ) { XCTAssertEqual($0 as? PaperNotePlace.Failure, .noSuchPage(page)) }
        }
        XCTAssertThrowsError(
            try PaperNotePlace.resolve(item: rig.item, document: nil, session: nil, choice: .startOfPage(2))
        ) { XCTAssertEqual($0 as? PaperNotePlace.Failure, .noSuchPage(2)) }
    }

    func testAPageWithNoTextOfItsOwnGivesTheNextTextAfterIt() throws {
        var document = makeDocument()
        document.segments.removeAll { $0.id == "s4" } // page 4 now has no text
        let rig = try makeRig(sessions: [])
        let start = try PaperNotePlace.resolve(item: rig.item, document: document, session: nil, choice: .startOfPage(4))
        XCTAssertEqual(start, offset(of: "Conclusion."))
    }

    func testStartOfPaperSkipsLeadingWhiteSpace() throws {
        let rig = try makeRig(sessions: [])
        var padded = rig.item
        padded.text = "\n\n  " + text
        XCTAssertEqual(try PaperNotePlace.resolve(item: padded, document: nil, session: nil, choice: .startOfPaper), 4)
        XCTAssertEqual(try PaperNotePlace.resolve(item: rig.item, document: nil, session: nil, choice: .startOfPaper), 0)
    }

    func testAnItemWithoutTextHasNoPlace() throws {
        var bare = try makeRig(sessions: []).item
        bare.text = nil
        for choice: PaperNotePlace.Choice in [.startOfPaper, .whereYouAre, .startOfPage(1)] {
            XCTAssertThrowsError(try PaperNotePlace.resolve(item: bare, document: makeDocument(), session: nil, choice: choice)) {
                XCTAssertEqual($0 as? PaperNotePlace.Failure, .noText)
            }
        }
    }

    // MARK: "Where you are", the three facts about a finished paper

    /// What each fact must not do: move the session's progress, completion, place or stamp.
    private func assertAnswerAtWhereYouAre(
        sessions: [Session], expectedStart: Int, expectedPage: Int, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try makeRig(sessions: sessions)
        let stored = try rig.store.loadSessions(itemId: "paper")
        let chosen = PaperNotePlace.session(addedAgainAt: nil, sessions: stored)
        let start = try PaperNotePlace.resolve(item: rig.item, document: rig.document, session: chosen, choice: .whereYouAre)
        XCTAssertEqual(start, expectedStart, file: file, line: line)

        let answer = try rig.engine.addWrittenInterjection(
            id: "d", sessionId: try XCTUnwrap(chosen, file: file, line: line).id, atCharacter: start, text: "My answer.", paperRole: .purpose
        )

        XCTAssertEqual(answer.anchor.startChar, expectedStart, file: file, line: line)
        XCTAssertEqual(page(atCharacter: answer.anchor.startChar, in: rig.document), expectedPage, file: file, line: line)
        for original in sessions {
            XCTAssertEqual(try rig.store.loadSession(id: original.id), original, "session \(original.id) is unchanged", file: file, line: line)
        }
    }

    func testAFinishedPaperAnswersOnItsLastSentence() throws {
        let finished = session("s1", status: "finished", phase: .finished, at: text.count, percent: 100)
        try assertAnswerAtWhereYouAre(sessions: [finished], expectedStart: offset(of: "Nothing more."), expectedPage: 5)
    }

    func testAPaperHeardTo99PercentAnswersOnItsLastSentence() throws {
        let nearEnd = session("s1", at: offset(of: "We end here."), percent: 99)
        try assertAnswerAtWhereYouAre(sessions: [nearEnd], expectedStart: offset(of: "Nothing more."), expectedPage: 5)
    }

    func testAPaperMarkedCompleteAt30PercentKeepsItsOwnPlace() throws {
        // Marking an item finished sets the item's mark, not the session's: the session stays where it was left.
        let place = offset(of: "Each lasted a week.")
        let partway = session("s1", at: place, percent: 30)
        try assertAnswerAtWhereYouAre(sessions: [partway], expectedStart: place, expectedPage: 2)
    }

    func testAnOlderFinishedSessionBesideANewerInProgressOneUsesTheNewerPlace() throws {
        let older = session("old", status: "finished", phase: .finished, at: text.count, percent: 100, updatedAt: 10)
        let place = offset(of: "This fits earlier work.")
        let newer = session("new", at: place, percent: 70, updatedAt: 20)
        try assertAnswerAtWhereYouAre(sessions: [older, newer], expectedStart: place, expectedPage: 4)
    }

    func testASessionPlayingAGeneratedTurnHasNoPlaceInThePaper() throws {
        var turn = session("s1", at: 12, percent: 20)
        for type in [TargetType.assistantTurnTTS, .summaryTurnTTS] {
            turn.currentTargetType = type
            XCTAssertThrowsError(
                try PaperNotePlace.resolve(item: makeRig(sessions: []).item, document: makeDocument(), session: turn, choice: .whereYouAre)
            ) { XCTAssertEqual($0 as? PaperNotePlace.Failure, .placeNotInPaper) }
        }
    }

    func testAPaperNeverStartedHasNoWhereYouAre() throws {
        let rig = try makeRig(sessions: [])
        XCTAssertNil(PaperNotePlace.session(addedAgainAt: nil, sessions: []))
        XCTAssertThrowsError(try PaperNotePlace.resolve(item: rig.item, document: rig.document, session: nil, choice: .whereYouAre)) {
            XCTAssertEqual($0 as? PaperNotePlace.Failure, .noSession)
        }
    }

    func testListeningThatFinishedBeforeTheItemWasAddedAgainDoesNotCount() throws {
        let finished = session("old", status: "finished", phase: .finished, at: text.count, percent: 100, updatedAt: 10)
        XCTAssertNotNil(PaperNotePlace.session(addedAgainAt: nil, sessions: [finished]))
        XCTAssertNil(PaperNotePlace.session(addedAgainAt: Date(timeIntervalSince1970: 50), sessions: [finished]),
                     "added again after it finished: the paper starts over")
        let partway = session("part", at: 40, percent: 20, updatedAt: 10)
        XCTAssertEqual(PaperNotePlace.session(addedAgainAt: Date(timeIntervalSince1970: 50), sessions: [partway])?.id, "part",
                       "a session left part way keeps its place")
    }
}
