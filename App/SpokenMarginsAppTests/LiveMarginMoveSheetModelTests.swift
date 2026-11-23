import XCTest
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #4233 Design 7a: Move to an Item's states and words. The sheet model is given its reads and its plan as closures; the
/// plan here is the real `LiveMarginMove.plan` over an in-memory Library.
@MainActor
final class LiveMarginMoveSheetModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func spoken(_ id: String, at offset: TimeInterval, hint: Int? = nil) -> LiveSessionMargin {
        var margin = LiveSessionMargin(id: id, text: "", markedAt: at(offset), audioPath: "SpokenMargins/interjections/\(id).m4a")
        margin.playingThen = hint.map { LiveSessionPlayingThen(itemId: "ep", positionMs: $0, source: .playerRun) }
        return margin
    }

    private func quick(_ margins: [LiveSessionMargin]) -> LiveSession {
        var session = LiveSession(id: "quick-1", title: "Quick session", startedAt: margins[0].markedAt, isQuick: true)
        for margin in margins { session.add(margin) }
        return session
    }

    private func repository() -> InMemorySessionRepository {
        let item = Item(
            id: "ep", title: "Tides", mediaType: "podcast", text: nil, externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/ep.mp3", durationMs: 600_000, nativeMediaId: "ep-audio"))
        let session = Session(
            id: "s-ep", itemId: "ep", createdAt: t0, updatedAt: t0, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: "ep-audio",
            position: Position(charOffset: 0, mediaTimeMs: 1_000), completionPercent: 1, playbackRate: 1)
        return InMemorySessionRepository(items: ["ep": item], sessions: ["s-ep": session], interjections: [:])
    }

    private func sheet(
        _ live: LiveSession, marginIds: Set<String>? = nil,
        choices: @escaping () async throws -> [StoredSessionMargin.ItemChoice] = { [.init(id: "ep", title: "Tides")] }
    ) -> LiveMarginMoveSheetModel {
        let repo = repository()
        return LiveMarginMoveSheetModel(session: live, marginIds: marginIds, loadChoices: choices) { margins, itemId in
            try LiveMarginMove.plan(margins: margins, session: live, itemId: itemId, repository: repo)
        }
    }

    func testLoadingFailedEmptyAndNoHits() async {
        let live = quick([spoken("a", at: 1)])
        let failing = sheet(live, choices: { throw SessionKitError.persistenceFailed("x") })
        XCTAssertEqual(failing.load, .loading)
        await failing.loadIfNeeded()
        XCTAssertEqual(failing.load, .failed)

        let empty = sheet(live, choices: { [] })
        await empty.loadIfNeeded()
        XCTAssertEqual(empty.emptyState, .nothingStarted)

        let loaded = sheet(live)
        await loaded.loadIfNeeded()
        XCTAssertNil(loaded.emptyState)
        loaded.query = "Cove"
        XCTAssertEqual(loaded.emptyState, .noHits("Cove"))
        loaded.query = "tídes"
        XCTAssertEqual(loaded.sections.recent.map(\.id), ["ep"], "case and accents are ignored")
    }

    func testTheDialogForOneAndThreeMargins() async {
        let rows: [(String, [LiveSessionMargin], String, String, String)] = [
            ("one placed", [spoken("a", at: 1, hint: 60_000)], "Move this Margin to “Tides”?",
             "It will sit where “Tides” was playing when you made it.", "Move Margin"),
            ("three placed", [spoken("a", at: 1, hint: 1_000), spoken("b", at: 2, hint: 2_000), spoken("c", at: 3, hint: 3_000)],
             "Move 3 Margins to “Tides”?", "They'll sit where “Tides” was playing when you made them.", "Move 3 Margins"),
            ("three unplaced", [spoken("a", at: 1), spoken("b", at: 2), spoken("c", at: 3)], "Move 3 Margins to “Tides”?",
             "No playback place was saved with them, so they'll be on the item without a place.", "Move 3 Margins"),
            ("one of three placed", [spoken("a", at: 1, hint: 1_000), spoken("b", at: 2), spoken("c", at: 3)], "Move 3 Margins to “Tides”?",
             "1 will sit where it was playing when you made it. 2 had no playback place saved and will be on the item without a place.",
             "Move 3 Margins"),
        ]
        for (name, margins, title, message, button) in rows {
            let model = sheet(quick(margins))
            XCTAssertEqual(model.movingLine, margins.count == 1 ? "Moving 1 Margin" : "Moving 3 Margins", name)
            await model.choose(itemId: "ep")
            XCTAssertEqual(model.dialogTitle, title, name)
            XCTAssertEqual(model.dialogMessage, message, name)
            XCTAssertEqual(model.confirmTitle, button, name)
        }
    }

    func testFromAMarginsSheetItMovesThatMarginOnly() {
        let model = sheet(quick([spoken("a", at: 1), spoken("b", at: 2)]), marginIds: ["b"])
        XCTAssertTrue(model.isSingleMargin)
        XCTAssertEqual(model.movingLine, "Moving this Margin")
        XCTAssertEqual(model.chosenMargins.map(\.id), ["b"])
    }

    func testChoosingNothingDimsDoneAndUnmovableMarginsCannotBeTicked() {
        var live = quick([spoken("a", at: 1)])
        live.add(LiveSessionMargin(id: "mark", text: "", markedAt: at(2), isBlindMark: true))
        let model = sheet(live)
        XCTAssertEqual(model.chosenIds, ["a"], "every Margin that can move starts chosen")
        model.toggle(live.margins[1])
        XCTAssertEqual(model.chosenIds, ["a"], "a Mark can't be ticked")
        XCTAssertEqual(model.unmovableReason(live.margins[1]), "A Mark has no words or recording to move.")
        model.toggle(live.margins[0])
        XCTAssertFalse(model.canFinishChoosing)
    }

    func testAFailedMoveSaysNothingChangedAndAGoneMarginSaysSo() async {
        let live = quick([spoken("a", at: 1)])
        let model = sheet(live)
        await model.choose(itemId: "ep")
        let moved = await model.confirm { _ in false }
        XCTAssertFalse(moved)
        XCTAssertEqual(model.failureLine, "Couldn't move the Margin. Nothing was changed.")

        let gone = LiveMarginMoveSheetModel(session: live, loadChoices: { [] }) { _, _ in throw LiveMarginMove.Failure.nothingToMove }
        await gone.choose(itemId: "ep")
        XCTAssertNil(gone.pendingPlan)
        XCTAssertEqual(gone.failureLine, "Those Margins are no longer in this session.")
    }

    func testConfirmRunsTheMoveOnce() async {
        let model = sheet(quick([spoken("a", at: 1)]))
        await model.choose(itemId: "ep")
        XCTAssertTrue(model.isAsking)
        // SwiftUI hides the dialog before the button's Task runs: the plan must still be there for it.
        model.isAsking = false
        var runs = 0
        let first = await model.confirm { _ in runs += 1; return true }
        let second = await model.confirm { _ in runs += 1; return true }
        XCTAssertTrue(first)
        XCTAssertFalse(second, "the plan is used up")
        XCTAssertEqual(runs, 1)
    }
}
