import XCTest
import SessionKit
import SessionKitPersistence
import AppIntents
import SQLite3
@testable import SpokenMarginsApp

@MainActor
final class PKMWorkflowTests: XCTestCase {
    func testAutomaticDeliveryRetriesWithoutDuplicatesAndPreservesExternalEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal = root.appendingPathComponent("journal.json")
        let writer = AutomaticMarginWriter(journalURL: journal)
        let note = AutomaticMarginWriter.Note(id: "session-a:margin-1", markdown: "# Thought\n\nOriginal")
        _ = try await writer.deliver([note], to: folder, destinationID: "vault")
        let restarted = AutomaticMarginWriter(journalURL: journal)
        _ = try await restarted.deliver([note], to: folder, destinationID: "vault")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        _ = try await restarted.deliver([.init(id: note.id, markdown: "Updated transcript")], to: folder, destinationID: "vault")
        XCTAssertEqual(try String(contentsOf: files[0], encoding: .utf8), "Updated transcript")
        try Data("My Obsidian edit".utf8).write(to: files[0])
        // #581: the edit is kept and counted, not reported as a failure.
        let summary = try await restarted.deliver([.init(id: note.id, markdown: "Another transcript"), .init(id: "unaffected", markdown: "Another independent Margin")], to: folder, destinationID: "vault")
        XCTAssertEqual(summary, MarginNoteDelivery.Summary(saved: 1, keptEdits: 1))
        XCTAssertEqual(try String(contentsOf: files[0], encoding: .utf8), "My Obsidian edit")
        let delivered = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(delivered.count, 2, "One conflict must not prevent independent delivery")
    }

    /// Build 29 wrote Margin notes without a properties block (#491). The writer must rewrite its
    /// own unedited notes once to gain the block, and still never overwrite a note edited outside the app.
    func testMarginNotesGainPropertiesOnceWithoutOverwritingEditedNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func note(_ marginID: String) throws -> String {
            let json = """
            {"schemaVersion": "spoken-margins.export.v1", "item": {"id": "item-a", "title": "Episode: \\"one\\"", "externalReference": "https://example.com/1", "includedFullText": false},
             "session": {"id": "session-a", "status": "in_progress", "completionPercent": 10},
             "turns": [], "timeline": [],
             "interjections": [{"id": "\(marginID)", "sessionId": "session-a", "targetType": "item", "targetId": "item-a",
               "roughPercent": 10, "anchorBefore": "Before.", "anchorAfter": "After.", "mediaTimeMs": 5000,
               "transcriptionStatus": "transcribed", "transcript": "A thought.", "audioPath": null}]}
            """
            let export = try JSONDecoder().decode(SessionExport.self, from: Data(json.utf8))
            return SessionExportMarkdownRenderer.renderMargin(export, createdAt: Date(timeIntervalSince1970: 1_777_000_000))
        }
        let current = [AutomaticMarginWriter.Note(id: "session-a:m1", markdown: try note("m1")),
                       AutomaticMarginWriter.Note(id: "session-a:m2", markdown: try note("m2"))]
        // The Build 29 note is the same body without the properties block.
        let build29 = try current.map { note in
            let parts = note.markdown.components(separatedBy: "\n---\n\n")
            XCTAssertTrue(note.markdown.hasPrefix("---\n"))
            return AutomaticMarginWriter.Note(id: note.id, markdown: try XCTUnwrap(parts.count == 2 ? parts[1] : nil))
        }
        let journal = root.appendingPathComponent("journal.json")
        _ = try await AutomaticMarginWriter(journalURL: journal).deliver(build29, to: folder, destinationID: "vault")
        func file(_ id: String) -> URL { folder.appendingPathComponent("Margin-\(ListeningEdition.digest(id)).md") }
        try Data("My Obsidian edit".utf8).write(to: file("session-a:m2"))

        let upgraded = AutomaticMarginWriter(journalURL: journal)
        let summary = try await upgraded.deliver(current, to: folder, destinationID: "vault")
        XCTAssertEqual(summary, MarginNoteDelivery.Summary(saved: 1, keptEdits: 1), "The edited note is kept, not overwritten")
        XCTAssertEqual(try String(contentsOf: file("session-a:m1"), encoding: .utf8), current[0].markdown)
        XCTAssertEqual(try String(contentsOf: file("session-a:m2"), encoding: .utf8), "My Obsidian edit")

        // Once: a second pass leaves the rewritten note's bytes and date alone.
        let written = try FileManager.default.attributesOfItem(atPath: file("session-a:m1").path)[.modificationDate] as? Date
        _ = try? await upgraded.deliver([current[0]], to: folder, destinationID: "vault")
        XCTAssertEqual(try String(contentsOf: file("session-a:m1"), encoding: .utf8), current[0].markdown)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file("session-a:m1").path)[.modificationDate] as? Date, written)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }

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

    private func delivery(_ fixture: (root: URL, store: SQLiteSessionStore, folder: URL), statuses: @escaping @MainActor (MarginOutputStatus) -> Void = { _ in }) -> MarginNotesDelivery {
        MarginNotesDelivery(
            isEnabled: { true },
            isRecording: { false },
            target: { .init(store: fixture.store, folder: fixture.folder, destinationID: "vault") },
            report: statuses,
            journalURL: { fixture.root.appendingPathComponent("journal.json") }
        )
    }

    func testAMarginSavedJustBeforeBackgroundingIsWrittenExactlyOnce() async throws {
        let fixture = try notesFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var statuses: [String] = []
        let delivery = delivery(fixture) { statuses.append($0.message) }
        try fixture.store.saveInterjection(spokenMargin(id: "ij-001", sessionId: "session-episode", itemId: "item-episode", transcript: "Said just before switching apps."))

        try await XCTUnwrap(delivery.finishBeforeBackground()).value

        XCTAssertEqual(try notes(in: fixture.folder).count, 1, statuses.joined(separator: "\n"))
        // More passes, backgrounding again, and a relaunch with a fresh writer add nothing.
        await delivery.pass()
        try await XCTUnwrap(delivery.finishBeforeBackground()).value
        await self.delivery(fixture).pass()
        let written = try notes(in: fixture.folder)
        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(written[0].contains("Said just before switching apps."))
        XCTAssertFalse(statuses.contains { $0.hasPrefix("Delivery needs attention") }, statuses.joined(separator: "\n"))
    }

    /// #1192: a pass every minute used to rebuild every note, changed or not (37 passes, 142 s in 18 minutes).
    func testAPassWithNothingNewBuildsNothingAndANewMarginBuildsOnlyItsNote() async throws {
        let fixture = try notesFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var gathers: [(sessions: Int, notes: Int)] = []
        let delivery = MarginNotesDelivery(
            isEnabled: { true },
            isRecording: { false },
            target: { .init(store: fixture.store, folder: fixture.folder, destinationID: "vault") },
            report: { _ in },
            recordGather: { _, sessions, notes in gathers.append((sessions, notes)) },
            journalURL: { fixture.root.appendingPathComponent("journal.json") }
        )
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
        let delivery = delivery(fixture)
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
        let firstLaunch = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        firstLaunch.resetAndSeed(); firstLaunch.declineCurrentTerms()
        firstLaunch.startItem(id: "item-pill")
        firstLaunch.pause()
        let restoredSessionID = try XCTUnwrap(firstLaunch.snapshot.sessionId)
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
