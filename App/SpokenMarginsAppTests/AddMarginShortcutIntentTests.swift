import AppIntents
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #571: the Add Margin shortcut action writes a text Margin on whatever is playing.
@MainActor
final class AddMarginShortcutIntentTests: XCTestCase {
    private func makeModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        // Finish the first-use system-voice choice; until then startItem waits on it and nothing plays.
        model.declineCurrentTerms()
        return model
    }

    private func run(_ text: String, on model: Gate1AppModel?) async throws {
        let priorModel = ListeningEditionShortcutBridge.model
        ListeningEditionShortcutBridge.model = model
        defer { ListeningEditionShortcutBridge.model = priorModel }
        let intent = AddMarginToSpokenMarginsIntent()
        intent.text = text
        _ = try await intent.perform()
    }

    func testAddsOneWrittenMarginToThePlayingItem() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        model.refreshMarginRows()
        let before = model.marginRows.count

        try await run("  Check this claim against the 2019 paper.  ", on: model)

        model.refreshMarginRows()
        XCTAssertEqual(model.marginRows.count, before + 1)
        let row = try XCTUnwrap(model.marginRows.first { $0.fullText == "Check this claim against the 2019 paper." })
        XCTAssertTrue(row.isWritten)
        XCTAssertEqual(row.interjection.itemId, "item-pill")
        XCTAssertEqual(row.interjection.sessionId, sessionId)
        XCTAssertEqual(row.interjection.status, "active")
        // The draft is closed and the session is the one that was playing.
        XCTAssertNil(model.writtenMarginDraft)
        XCTAssertEqual(model.snapshot.sessionId, sessionId)
    }

    func testPlayingSourceKeepsPlayingAfterTheMargin() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        XCTAssertEqual(model.snapshot.status, .playing)
        try await run("Keep going.", on: model)
        XCTAssertEqual(model.snapshot.status, .playing)
    }

    func testPausedSourceStaysPausedAfterTheMargin() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        model.pause()
        XCTAssertEqual(model.snapshot.status, .paused)
        try await run("A note while paused.", on: model)
        XCTAssertEqual(model.snapshot.status, .paused)
        model.refreshMarginRows()
        XCTAssertTrue(model.marginRows.contains { $0.fullText == "A note while paused." })
    }

    func testNothingPlayingThrowsAndCreatesNoMargin() async throws {
        let model = makeModel()
        XCTAssertFalse(model.hasActiveSession)
        model.refreshMarginRows()
        let before = model.marginRows.count

        do {
            try await run("Orphan.", on: model)
            XCTFail("The action must refuse when nothing is playing.")
        } catch let error as AddMarginShortcutError {
            XCTAssertEqual(error, .nothingPlaying)
            XCTAssertTrue(error.localizedDescription.contains("Nothing is playing in Spoken Margins"))
        }

        model.refreshMarginRows()
        XCTAssertEqual(model.marginRows.count, before)
        XCTAssertNil(model.writtenMarginDraft)
        XCTAssertFalse(model.hasActiveSession)
    }

    func testEmptyTextThrowsBeforePlaybackIsTouched() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        model.refreshMarginRows()
        let before = model.marginRows.count

        do {
            try await run(" \n\t ", on: model)
            XCTFail("The action must refuse an empty Margin.")
        } catch let error as AddMarginShortcutError {
            XCTAssertEqual(error, .emptyText)
        }

        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertNil(model.writtenMarginDraft)
        model.refreshMarginRows()
        XCTAssertEqual(model.marginRows.count, before)
    }

    func testAMarginAlreadyBeingWrittenIsLeftAlone() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        model.beginWrittenMargin()
        let draft = try XCTUnwrap(model.writtenMarginDraft)

        do {
            try await run("Second note.", on: model)
            XCTFail("The action must not overwrite a Margin the listener is writing.")
        } catch let error as AddMarginShortcutError {
            XCTAssertEqual(error, .writingInProgress)
        }

        XCTAssertEqual(model.writtenMarginDraft?.captureID, draft.captureID)
        model.cancelWrittenMargin()
    }

    func testMissingLibraryThrowsAClearError() async throws {
        do {
            try await run("No model.", on: nil)
            XCTFail("The action must refuse when the app model isn't available.")
        } catch let error as AddMarginShortcutError {
            XCTAssertEqual(error, .libraryUnavailable)
        }
    }
}
