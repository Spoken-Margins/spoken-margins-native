import AppIntents
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #571: the Add Margin shortcut action writes a text Margin on whatever is playing.
/// #1073: given a Library item that isn't playing, it writes on that item's saved session instead.
@MainActor
final class AddMarginShortcutIntentTests: XCTestCase {
    private func makeModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        // Finish the first-use system-voice choice; until then startItem waits on it and nothing plays.
        model.declineCurrentTerms()
        return model
    }

    private func run(_ text: String, item: LibraryItemEntity? = nil, on model: Gate1AppModel?) async throws {
        let priorModel = ListeningEditionShortcutBridge.model
        ListeningEditionShortcutBridge.model = model
        defer { ListeningEditionShortcutBridge.model = priorModel }
        let intent = AddMarginToSpokenMarginsIntent()
        intent.text = text
        intent.item = item
        _ = try await intent.perform()
        await model?.settleMarginRows()
    }

    /// #126: without an App Shortcut Siri can't run "Add Margin" until the listener builds a shortcut around it.
    func testAddMarginIsOfferedToSiriAsAnAppShortcut() {
        XCTAssertEqual(SpokenMarginsAppShortcuts.appShortcuts.count, 1)
    }

    private let sampleId = Gate1AppModel.welcomeSampleItemId

    /// The welcome sample has been listened to and left at `offset`, and "item-pill" is the item playing.
    private func modelPlayingPillWithSampleSavedAt(offset: Int) throws -> (model: Gate1AppModel, sampleSessionId: String) {
        let model = makeModel()
        model.addSampleItem()
        model.startItem(id: sampleId)
        let sampleSessionId = try XCTUnwrap(model.snapshot.sessionId)
        model.startItem(id: "item-pill")
        XCTAssertEqual(model.snapshot.itemId, "item-pill")
        XCTAssertEqual(model.snapshot.status, .playing)
        let store = try XCTUnwrap(model.store)
        var saved = try XCTUnwrap(store.loadSession(id: sampleSessionId))
        saved.position.charOffset = offset
        try store.saveSession(saved)
        return (model, sampleSessionId)
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

    /// Audit on #2747: the Margins tab's full read is still running when Siri saves a Margin. The one-item refresh
    /// shows it first; when the older full read lands it must not take the new Margin back off the list.
    func testAMarginSavedWhileTheFullListIsBeingReadStaysOnTheList() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        model.refreshMarginRows()
        // resetAndSeed and startItem leave background full reads running. Let them land first, so the read held
        // below is the one this test starts and not a leftover that happens to land first (#2768).
        await model.settleMarginRows()
        let text = "Saved while the Margins tab loads."
        let gate = FullReadGate()
        defer { MarginRowsTickets.fullReadLanded = nil }
        // Hold the full read after it has read the store and before it publishes.
        await withCheckedContinuation { (reached: CheckedContinuation<Void, Never>) in
            MarginRowsTickets.fullReadLanded = {
                MarginRowsTickets.fullReadLanded = nil // only the first landing is held
                await withCheckedContinuation { gate.release = $0; reached.resume() }
            }
            model.refreshMarginRowsInBackground()
        }

        let priorModel = ListeningEditionShortcutBridge.model
        ListeningEditionShortcutBridge.model = model
        defer { ListeningEditionShortcutBridge.model = priorModel }
        let intent = AddMarginToSpokenMarginsIntent()
        intent.text = text
        _ = try await intent.perform()
        await model.refreshMarginRowsAsync(forItem: "item-pill")
        XCTAssertTrue(model.marginRows.contains { $0.fullText == text }, "the one-item refresh shows the new Margin")

        try XCTUnwrap(gate.release).resume()
        await model.settleMarginRows()
        XCTAssertTrue(model.marginRows.contains { $0.fullText == text }, "the older full read must not hide it")
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

    // MARK: - An item that isn't playing (#1073)

    func testItemThatIsNotPlayingGetsTheMarginAtItsSavedPlaceAndThePlayingItemCarriesOn() async throws {
        let (model, sampleSessionId) = try modelPlayingPillWithSampleSavedAt(offset: 120)
        let playingSessionId = try XCTUnwrap(model.snapshot.sessionId)
        let store = try XCTUnwrap(model.store)
        let sampleUpdatedAt = try XCTUnwrap(store.loadSession(id: sampleSessionId)?.updatedAt)
        model.refreshMarginRows()
        let before = model.marginRows.count

        try await run("  Back to this later.  ", item: LibraryItemEntity(id: sampleId, title: "Welcome"), on: model)

        model.refreshMarginRows()
        XCTAssertEqual(model.marginRows.count, before + 1)
        let row = try XCTUnwrap(model.marginRows.first { $0.fullText == "Back to this later." })
        XCTAssertTrue(row.isWritten)
        XCTAssertEqual(row.interjection.itemId, sampleId)
        XCTAssertEqual(row.interjection.sessionId, sampleSessionId)
        XCTAssertEqual(row.interjection.status, "active")
        XCTAssertEqual(row.interjection.anchor.startChar, 120, "the sample's saved place, not where the playing item is")
        // Nothing about the playing item changed.
        XCTAssertEqual(model.snapshot.itemId, "item-pill")
        XCTAssertEqual(model.snapshot.sessionId, playingSessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertNil(model.writtenMarginDraft)
        XCTAssertFalse(model.marginRows.contains { $0.interjection.sessionId == playingSessionId })
        // The sample's session is where the listener left it, and not pulled ahead of the playing item's.
        XCTAssertEqual(try store.loadSession(id: sampleSessionId)?.position.charOffset, 120)
        XCTAssertEqual(try store.loadSession(id: sampleSessionId)?.updatedAt, sampleUpdatedAt)
        XCTAssertEqual(try store.loadSessions(itemId: sampleId).count, 1)
    }

    func testNamingThePlayingItemIsTheCurrentItemCase() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)

        try await run("On the item itself.", item: LibraryItemEntity(id: "item-pill", title: "Pill"), on: model)

        model.refreshMarginRows()
        let row = try XCTUnwrap(model.marginRows.first { $0.fullText == "On the item itself." })
        XCTAssertTrue(row.isWritten)
        XCTAssertEqual(row.interjection.itemId, "item-pill")
        XCTAssertEqual(row.interjection.sessionId, sessionId)
        XCTAssertEqual(model.snapshot.sessionId, sessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertNil(model.writtenMarginDraft)
    }

    func testItemWithNoSessionThrowsAndCreatesNoMargin() async throws {
        let model = makeModel()
        model.addSampleItem()
        model.startItem(id: "item-pill")
        let store = try XCTUnwrap(model.store)
        XCTAssertTrue(try store.loadSessions(itemId: sampleId).isEmpty)
        model.refreshMarginRows()
        let before = model.marginRows.count

        do {
            try await run("Too early.", item: LibraryItemEntity(id: sampleId, title: "Welcome"), on: model)
            XCTFail("The action must not create a session just to write on it.")
        } catch let error as AddMarginShortcutError {
            XCTAssertEqual(error, .itemNotStarted)
            XCTAssertEqual(error.localizedDescription, "Start this item once before adding a Margin to it.")
        }

        model.refreshMarginRows()
        XCTAssertEqual(model.marginRows.count, before)
        XCTAssertTrue(try store.loadSessions(itemId: sampleId).isEmpty)
        XCTAssertEqual(model.snapshot.itemId, "item-pill")
        XCTAssertEqual(model.snapshot.status, .playing)
    }

    func testItemThatIsNotInTheLibraryThrows() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")

        do {
            try await run("Lost.", item: LibraryItemEntity(id: "item-gone", title: "Gone"), on: model)
            XCTFail("The action must refuse an item that isn't in the Library.")
        } catch let error as AddMarginShortcutError {
            XCTAssertEqual(error, .itemNotFound)
        }
        XCTAssertEqual(model.snapshot.status, .playing)
    }

    func testEmptyTextForAnotherItemThrowsBeforeAnythingIsWritten() async throws {
        let (model, _) = try modelPlayingPillWithSampleSavedAt(offset: 120)
        model.refreshMarginRows()
        let before = model.marginRows.count

        do {
            try await run(" \n ", item: LibraryItemEntity(id: sampleId, title: "Welcome"), on: model)
            XCTFail("The action must refuse an empty Margin.")
        } catch let error as AddMarginShortcutError {
            XCTAssertEqual(error, .emptyText)
        }
        model.refreshMarginRows()
        XCTAssertEqual(model.marginRows.count, before)
    }

    func testThePickerOffersStartedItemsAndASavedChoiceStillResolves() async throws {
        let model = makeModel()
        model.addSampleItem()
        model.startItem(id: "item-pill")
        let priorModel = ListeningEditionShortcutBridge.model
        ListeningEditionShortcutBridge.model = model
        defer { ListeningEditionShortcutBridge.model = priorModel }
        let query = LibraryItemEntityQuery()

        let suggested = try await query.suggestedEntities().map(\.id)
        XCTAssertEqual(suggested, ["item-pill"], "the sample was never started")
        let resolved = try await query.entities(for: [sampleId, "item-pill", "item-gone"]).map(\.id)
        XCTAssertEqual(Set(resolved), [sampleId, "item-pill"])
    }
}

/// Holds a background Margins read until the test lets it go.
@MainActor
private final class FullReadGate {
    var release: CheckedContinuation<Void, Never>?
}
