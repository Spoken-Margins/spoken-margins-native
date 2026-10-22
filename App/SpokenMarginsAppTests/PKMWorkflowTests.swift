import XCTest
import SessionKit
import SessionKitPersistence
import AppIntents
import SQLite3
@testable import SpokenMarginsApp

@MainActor
final class PKMWorkflowTests: XCTestCase {
    func testEditionImportPreservesActiveSessionAndRejectsSilentMapReplacement() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed(); model.declineCurrentTerms()
        model.importTitle = "Existing"; model.importText = "Keep the ongoing session."
        model.importTextItem(); model.pause()
        let activeSession = model.snapshot.sessionId
        var edition = ListeningEdition(title: "Imported", text: "An article " + UUID().uuidString,
            generator: "External model", overview: "Overview", scenes: [.init(title: "A", description: "Description", summary: "Summary", startBlock: 1, endBlock: 1)])
        defer { try? FileManager.default.removeItem(at: ListeningEditionStore.application().file(edition.itemID)) }
        model.importListeningEditionData(try edition.encoded())
        XCTAssertEqual(model.snapshot.sessionId, activeSession)
        XCTAssertEqual(model.selectedItem.id, edition.itemID)
        model.importListeningEditionData(try edition.encoded())
        XCTAssertEqual(model.libraryItems.filter { $0.id == edition.itemID }.count, 1)
        edition.scenes[0].summary = "Changed"
        model.importListeningEditionData(try edition.encoded())
        XCTAssertEqual(try ListeningEditionStore.application().load(itemID: edition.itemID)?.scenes[0].summary, "Summary")
        model.importListeningEditionData(try edition.encoded(), replaceMap: true)
        XCTAssertEqual(try ListeningEditionStore.application().load(itemID: edition.itemID)?.scenes[0].summary, "Changed")
    }

    func testBatchEditionImportSavesEveryFileInOneOperationAndStaysWhereTheListenerIs() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed(); model.declineCurrentTerms()
        model.importTitle = "Existing"; model.importText = "Keep the ongoing session."
        model.importTextItem(); model.pause()
        let activeSession = model.snapshot.sessionId
        let activeItem = model.activeItemId
        let screen = model.screen
        func make(_ title: String) -> ListeningEdition {
            ListeningEdition(title: title, text: title + " " + UUID().uuidString, generator: "External model", overview: "Overview",
                             scenes: [.init(title: "A", description: "Description", summary: "Summary", startBlock: 1, endBlock: 1)])
        }
        let first = make("Batch one"), second = make("Batch two")
        var different = first
        different.scenes[0].summary = "A different map for the same source"
        defer { for e in [first, second] { try? FileManager.default.removeItem(at: ListeningEditionStore.application().file(e.itemID)) } }

        let lines = model.importListeningEditions([
            .init(id: 0, name: "one.json", data: try first.encoded()),
            .init(id: 1, name: "broken.json", data: Data("not json".utf8)),
            .init(id: 2, name: "two.json", data: try second.encoded()),
            .init(id: 3, name: "one-again.json", data: try first.encoded()),
            .init(id: 4, name: "one-different.json", data: try different.encoded()),
        ])

        XCTAssertEqual(lines.map(\.id), [0, 1, 2, 3, 4])
        XCTAssertEqual([lines[0].outcome, lines[2].outcome, lines[3].outcome, lines[4].outcome],
                       [.imported, .imported, .alreadyImported, .keptExistingMap])
        guard case .failed = lines[1].outcome else { return XCTFail("the malformed file should have its own failed line") }
        // Both valid editions are in the Library and saved, and the different map did not replace the first.
        XCTAssertEqual(model.libraryItems.filter { $0.id == first.itemID }.count, 1)
        XCTAssertEqual(model.libraryItems.filter { $0.id == second.itemID }.count, 1)
        XCTAssertEqual(try ListeningEditionStore.application().load(itemID: first.itemID), first)
        XCTAssertEqual(try ListeningEditionStore.application().load(itemID: second.itemID), second)
        // A batch opens nothing and leaves the current session alone.
        XCTAssertEqual(model.screen, screen)
        XCTAssertEqual(model.activeItemId, activeItem)
        XCTAssertEqual(model.snapshot.sessionId, activeSession)
    }

    /// #2373: collections picked from + > Files (real temp files, the picker's URLs) land in the Library like a PDF
    /// added there, and a JSON file that is not an edition is a clear failure that does not stop the others.
    func testCollectionFilesPickedFromTheAddSheetLandInTheLibraryAndABadOneSaysSo() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed(); model.declineCurrentTerms()
        model.importTitle = "Existing"; model.importText = "Keep the ongoing session."
        model.importTextItem(); model.pause()
        let activeItem = model.activeItemId
        let screen = model.screen
        func make(_ title: String) -> ListeningEdition {
            ListeningEdition(title: title, text: title + " " + UUID().uuidString, generator: "External model", overview: "Overview",
                             scenes: [.init(title: "A", description: "Description", summary: "Summary", startBlock: 1, endBlock: 1)])
        }
        let first = make("Files one"), second = make("Files two")
        defer { for e in [first, second] { try? FileManager.default.removeItem(at: ListeningEditionStore.application().file(e.itemID)) } }
        let directory = FileManager.default.temporaryDirectory.appending(path: "collection-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, _ data: Data) throws -> URL {
            let url = directory.appending(path: name)
            try data.write(to: url)
            return url
        }
        let oneURL = try write("one.json", try first.encoded())
        let twoURL = try write("two.json", try second.encoded())
        let notAnEdition = try write("notes.json", Data(#"{"hello": "world"}"#.utf8))

        XCTAssertTrue(model.importListeningEditionFiles([oneURL, twoURL]))
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.libraryItems.filter { $0.id == first.itemID }.count, 1)
        XCTAssertEqual(model.libraryItems.filter { $0.id == second.itemID }.count, 1)
        XCTAssertEqual(try ListeningEditionStore.application().load(itemID: first.itemID), first)
        XCTAssertEqual(model.screen, screen, "a file added from the sheet opens nothing")
        XCTAssertEqual(model.activeItemId, activeItem)

        XCTAssertFalse(model.importListeningEditionFiles([notAnEdition]), "a non-edition JSON file is not imported")
        XCTAssertEqual(model.lastError?.contains("notes.json"), true, model.lastError ?? "no error")
        XCTAssertEqual(model.libraryItems.filter { $0.id == first.itemID }.count, 1, "nothing else changed")
    }

    func testShortcutIntentImportsAndOpensEditionWithoutURLLaunch() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed(); model.declineCurrentTerms()
        let priorModel = ListeningEditionShortcutBridge.model
        ListeningEditionShortcutBridge.model = model
        defer { ListeningEditionShortcutBridge.model = priorModel }
        let edition = ListeningEdition(title: "Shortcut article", text: "Source " + UUID().uuidString,
            generator: "Ask ChatGPT", overview: "Overview", scenes: [.init(title: "One", description: "Description", summary: "Summary", startBlock: 1, endBlock: 1)])
        defer { try? FileManager.default.removeItem(at: ListeningEditionStore.application().file(edition.itemID)) }
        let intent = ImportListeningEditionIntent()
        intent.file = IntentFile(data: try edition.encoded(), filename: "Listening Edition.json", type: .json)
        _ = try await intent.perform()
        XCTAssertEqual(model.selectedItem.id, edition.itemID)
        XCTAssertEqual(try ListeningEditionStore.application().load(itemID: edition.itemID), edition)
        XCTAssertEqual(model.libraryItems.filter { $0.id == edition.itemID }.count, 1)
    }

    func testShortcutIntentImportsFromJSONTextWithNoFile() async throws {
        // #574: the share-sheet shortcut passes the edition's JSON, with no file picker.
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed(); model.declineCurrentTerms()
        let priorModel = ListeningEditionShortcutBridge.model
        ListeningEditionShortcutBridge.model = model
        defer { ListeningEditionShortcutBridge.model = priorModel }
        let edition = ListeningEdition(title: "Shortcut text article", text: "Source " + UUID().uuidString,
            generator: "Ask ChatGPT", overview: "Overview", scenes: [.init(title: "One", description: "Description", summary: "Summary", startBlock: 1, endBlock: 1)])
        defer { try? FileManager.default.removeItem(at: ListeningEditionStore.application().file(edition.itemID)) }
        let intent = ImportListeningEditionIntent()
        intent.json = String(decoding: try edition.encoded(), as: UTF8.self)
        _ = try await intent.perform()
        XCTAssertEqual(model.selectedItem.id, edition.itemID)
        XCTAssertEqual(try ListeningEditionStore.application().load(itemID: edition.itemID), edition)
        let empty = ImportListeningEditionIntent()
        do { _ = try await empty.perform(); XCTFail("an import with no file and no text must fail") }
        catch { XCTAssertTrue((error as? EditionError)?.errorDescription?.contains("Assemble Listening Edition") == true) }
    }

    // MARK: - Every spoken Margin reaches the notes folder (#171)

    private func spokenMargin(id: String, sessionId: String, itemId: String, transcript: String?) -> Interjection {
        Interjection(
            id: id, itemId: itemId, sessionId: sessionId, targetType: .item, targetId: itemId,
            createdAt: Date(timeIntervalSince1970: 1_777_000_000), roughPercent: 10,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "Before.", anchorAfter: "After.", mediaTimeMs: 65_000),
            audioPath: "Interjections/\(id).m4a", audioStatus: "saved",
            transcriptionStatus: transcript == nil ? "failed" : "transcribed", transcript: transcript, cleanedTranscript: nil,
            displayText: transcript, status: "active", captureKind: .audio
        )
    }

    /// A temp Library with one podcast item and session, and a temp notes folder.
    private func notesFixture() throws -> (root: URL, store: SQLiteSessionStore, folder: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-notes-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        try store.saveItem(Item(id: "item-episode", title: "An episode", mediaType: "audio", text: nil,
                                externalReference: "https://example.com/episode", status: "ready"))
        try store.saveSession(Session(id: "session-episode", itemId: "item-episode", status: "in_progress", phase: .itemPlayback,
                                      currentTargetType: .transcriptBackedMedia, currentTargetId: "item-episode",
                                      position: Position(mediaTimeMs: 65_000), completionPercent: 10, playbackRate: 1))
        return (root, store, folder)
    }

    private func notes(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
    }

    func testASpokenMarginWithoutATranscriptIsWrittenAndThenRewrittenWhenItArrives() async throws {
        let fixture = try notesFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.store.saveInterjection(spokenMargin(id: "ij-001", sessionId: "session-episode", itemId: "item-episode", transcript: nil))
        let writer = AutomaticMarginWriter(journalURL: fixture.root.appendingPathComponent("journal.json"))

        let first = try await AutomaticMarginNoteGatherer.gather(store: fixture.store)
        XCTAssertEqual(first.notes.count, 1, "a spoken Margin without a transcript used to be skipped")
        _ = try await writer.deliver(first.notes, to: fixture.folder, destinationID: "vault")
        let pending = try XCTUnwrap(try notes(in: fixture.folder).first)
        XCTAssertTrue(pending.contains("Transcript not available yet."), pending)
        XCTAssertTrue(pending.contains("Position: 01:05"), pending)
        XCTAssertTrue(pending.contains("(spokenmargins://margin?session=session-episode&margin=ij-001)"), pending)

        try fixture.store.saveInterjection(spokenMargin(id: "ij-001", sessionId: "session-episode", itemId: "item-episode", transcript: "It arrived."))
        let second = try await AutomaticMarginNoteGatherer.gather(store: fixture.store)
        _ = try await writer.deliver(second.notes, to: fixture.folder, destinationID: "vault")
        let written = try notes(in: fixture.folder)
        XCTAssertEqual(written.count, 1, "the transcript rewrites the same note")
        XCTAssertTrue(written[0].contains("It arrived."), written[0])
        XCTAssertFalse(written[0].contains("Transcript not available yet."))
    }

    /// The one notes folder of Build 29, as a destination whose id is `vault`.
    private func delivery(
        _ fixture: (root: URL, store: SQLiteSessionStore, folder: URL),
        recordGather: @escaping @MainActor (Int, Int, Int) -> Void = { _, _, _ in }
    ) throws -> MarginOutputCoordinator {
        let destinations = MarginOutputDestinationStore(fileURL: fixture.root.appendingPathComponent("destinations.json"))
        if try destinations.load() == nil {
            try destinations.save([MarginOutputDestination(id: "vault", name: "Vault", bookmark: try MarginOutputCoordinator.FolderAccess.live.makeBookmark(fixture.folder))])
        }
        return MarginOutputCoordinator(
            store: { fixture.store },
            isRecording: { false },
            recordGather: recordGather,
            destinationStore: destinations,
            journalURL: { fixture.root.appendingPathComponent("journal.json") }
        )
    }

    func testAMarginSavedJustBeforeBackgroundingIsWrittenExactlyOnce() async throws {
        let fixture = try notesFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let delivery = try delivery(fixture)
        try fixture.store.saveInterjection(spokenMargin(id: "ij-001", sessionId: "session-episode", itemId: "item-episode", transcript: "Said just before switching apps."))

        try await XCTUnwrap(delivery.finishBeforeBackground()).value

        XCTAssertEqual(try notes(in: fixture.folder).count, 1, delivery.statuses["vault"]?.message ?? "no status")
        // More passes, backgrounding again, and a relaunch with a fresh writer add nothing.
        await delivery.pass()
        try await XCTUnwrap(delivery.finishBeforeBackground()).value
        let relaunched = try self.delivery(fixture)
        await relaunched.pass()
        let written = try notes(in: fixture.folder)
        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(written[0].contains("Said just before switching apps."))
        XCTAssertFalse(delivery.statuses["vault"]?.message.hasPrefix("Delivery needs attention") == true, delivery.statuses["vault"]?.message ?? "")
        XCTAssertFalse(relaunched.statuses["vault"]?.message.hasPrefix("Delivery needs attention") == true)
    }

    /// #1192: a pass every minute used to rebuild every note, changed or not (37 passes, 142 s in 18 minutes).
    func testAPassWithNothingNewBuildsNothingAndANewMarginBuildsOnlyItsNote() async throws {
        let fixture = try notesFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var gathers: [(sessions: Int, notes: Int)] = []
        let delivery = try delivery(fixture) { _, sessions, notes in gathers.append((sessions, notes)) }
        func ageEverything() {
            var raw: OpaquePointer?
            XCTAssertEqual(sqlite3_open(fixture.root.appendingPathComponent("library.sqlite").path, &raw), SQLITE_OK)
            defer { sqlite3_close(raw) }
            XCTAssertEqual(sqlite3_exec(raw, "UPDATE records SET updated_at = '2020-01-01 00:00:00';", nil, nil, nil), SQLITE_OK)
        }
        try fixture.store.saveInterjection(spokenMargin(id: "ij-001", sessionId: "session-episode", itemId: "item-episode", transcript: "First."))
        await delivery.pass()
        XCTAssertEqual(gathers.count, 1)
        XCTAssertEqual(try notes(in: fixture.folder).count, 1)
        ageEverything()

        await delivery.pass()
        await delivery.pass()
        XCTAssertEqual(gathers.count, 1, "nothing changed, so no pass read any session")

        try fixture.store.saveInterjection(spokenMargin(id: "ij-002", sessionId: "session-episode", itemId: "item-episode", transcript: "Second."))
        await delivery.pass()
        XCTAssertEqual(gathers.count, 2)
        XCTAssertEqual(gathers.last?.sessions, 1)
        XCTAssertEqual(try notes(in: fixture.folder).count, 2)
    }

    func testSavingAMarginStartsAPassWithinFiveSeconds() async throws {
        let fixture = try notesFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let delivery = try delivery(fixture)
        try fixture.store.saveInterjection(spokenMargin(id: "ij-002", sessionId: "session-episode", itemId: "item-episode", transcript: "Quick."))

        let started = Date()
        delivery.deliverSoon()
        delivery.deliverSoon() // A second request doesn't push the first back.
        while try notes(in: fixture.folder).isEmpty, Date().timeIntervalSince(started) < 5 {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try notes(in: fixture.folder).count, 1, "not delivered within 5 s")
        delivery.stop()
    }

    func testAMarginLinkOpensThatMarginInTheTimeline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: url.path)
        try store.saveSession(Session(id: "session-linked", itemId: "item-pill", status: "paused", phase: .itemPlayback,
                                      currentTargetType: .itemTextTTS, currentTargetId: "item-pill",
                                      position: Position(charOffset: 10), completionPercent: 5, playbackRate: 1))
        var margin = spokenMargin(id: "ij-007", sessionId: "session-linked", itemId: "item-pill", transcript: "Linked thought.")
        margin.anchor = Anchor(anchorType: .text, startChar: 10, endChar: 20, anchorBefore: "Before", anchorAfter: "After")
        try store.saveInterjection(margin)

        model.handleIncomingURL(MarginDeepLink(sessionId: "session-linked", marginId: "ij-007").url)

        XCTAssertEqual(model.screen, .timeline)
        XCTAssertEqual(model.requestedTimelineFocusMarginID, "session-linked::ij-007")

        model.handleIncomingURL(MarginDeepLink(sessionId: "session-linked", marginId: "ij-missing").url)
        XCTAssertEqual(model.lastError, "This Margin is no longer in your Library.")
    }

    /// #638: a cold launch restores another session paused, and the link still opens its own Margin.
    func testAMarginLinkOpensItsTimelineAfterLaunchRestoresAnotherPausedSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-link-restored-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        // Declining the Terms choice writes the voice into the app's shared preferences; put them back afterwards (#1448).
        let voicePreferences = VoicePreferencesSnapshot.capture()
        addTeardownBlock { voicePreferences.restore() }
        let firstLaunch = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        firstLaunch.resetAndSeed(); firstLaunch.declineCurrentTerms()
        firstLaunch.startItem(id: "item-pill")
        firstLaunch.pause()
        // A start that stopped early leaves no session id (#1198: the Terms sheet held it on a fresh simulator); say why.
        let restoredSessionID = try XCTUnwrap(
            firstLaunch.snapshot.sessionId,
            "no session after start and pause: terms gate \(firstLaunch.diagnostics["termsGate"] ?? "none"), "
                + "Terms sheet shown \(firstLaunch.isTermsOfUsePresented), status \"\(firstLaunch.statusMessage)\", "
                + "error \(firstLaunch.lastError ?? "none")"
        )
        let store = try SQLiteSessionStore(path: url.path)
        let restoredPosition = try XCTUnwrap(store.loadSession(id: restoredSessionID)).position
        try store.saveItem(Item(id: "item-linked", title: "An older article", mediaType: "text",
                                text: "An older article the listener finished, with a Margin worth coming back to.",
                                externalReference: "local", status: "ready"))
        try store.saveSession(Session(id: "session-linked", itemId: "item-linked", status: "finished", phase: .finished,
                                      currentTargetType: .itemTextTTS, currentTargetId: "item-linked",
                                      position: Position(charOffset: 20), completionPercent: 100, playbackRate: 1))
        var margin = spokenMargin(id: "ij-linked", sessionId: "session-linked", itemId: "item-linked", transcript: "Worth coming back to.")
        margin.anchor = Anchor(anchorType: .text, startChar: 10, endChar: 20, anchorBefore: "Before", anchorAfter: "After")
        try store.saveInterjection(margin)

        let relaunched = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        relaunched.handleIncomingURL(MarginDeepLink(sessionId: "session-linked", marginId: "ij-linked").url)

        XCTAssertEqual(relaunched.diagnostics["restoredSession"], restoredSessionID, "launch restores the other session first")
        XCTAssertNil(relaunched.diagnostics["marginTimelineNavigation"])
        XCTAssertEqual(relaunched.snapshot.sessionId, "session-linked")
        XCTAssertEqual(relaunched.screen, .timeline)
        XCTAssertEqual(relaunched.requestedTimelineFocusMarginID, "session-linked::ij-linked")
        XCTAssertFalse(relaunched.activePlaybackIsPlaying, "opening a link starts nothing")
        let restored = try XCTUnwrap(store.loadSession(id: restoredSessionID))
        XCTAssertEqual(restored.position, restoredPosition, "the paused session keeps its place")
        XCTAssertTrue(Gate1AppModel.isResumableSession(restored))
    }
}
