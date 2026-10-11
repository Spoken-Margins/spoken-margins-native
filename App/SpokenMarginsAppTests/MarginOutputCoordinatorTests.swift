import XCTest
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// Margin Output with more than one destination (#492), against a real Library, real folders and the real writer.
/// The one thing faked is a folder the app has lost access to, since a test can't revoke a real bookmark.
@MainActor
final class MarginOutputCoordinatorTests: XCTestCase {
    /// Bookmarks the fake treats as revoked.
    private final class Revoked: @unchecked Sendable {
        private let lock = NSLock()
        private var bookmarks: Set<Data> = []
        private var refreshes: [Data: Data] = [:]
        func revoke(_ bookmark: Data) { lock.lock(); bookmarks.insert(bookmark); lock.unlock() }
        /// The next resolve of `old` reports it stale and hands back `new`, as iOS does for a moved or renamed folder.
        func refresh(_ old: Data, to new: Data) { lock.lock(); refreshes[old] = new; lock.unlock() }
        func refreshed(_ bookmark: Data) -> Data? { lock.lock(); defer { lock.unlock() }; return refreshes[bookmark] }
        func contains(_ bookmark: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return bookmarks.contains(bookmark) }
    }

    /// A temp Library with one article and session, temp folders, and a coordinator over them. It cleans up after itself.
    @MainActor
    private final class Fixture {
        let root: URL
        let store: SQLiteSessionStore
        let revoked = Revoked()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-output-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
            try store.saveItem(Item(id: "item-1", title: "An article", mediaType: "text", text: "Opening. Middle. End.",
                                    externalReference: "https://example.com/article", status: "ready"))
            try store.saveSession(Session(id: "session-1", itemId: "item-1", status: "active", phase: .itemPlayback,
                                          currentTargetType: .itemTextTTS, currentTargetId: "item-1",
                                          position: Position(charOffset: 5), completionPercent: 10, playbackRate: 1))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func addMargin(_ id: String, text: String, starred: Bool = false) throws {
            try store.saveInterjection(Interjection(
                id: id, itemId: "item-1", sessionId: "session-1", targetType: .item, targetId: "item-1",
                createdAt: Date(timeIntervalSince1970: 1_777_000_100), roughPercent: 10,
                anchor: Anchor(anchorType: .text, startChar: 9, endChar: 15, anchorBefore: "Opening.", anchorAfter: "End."),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: text, cleanedTranscript: nil,
                displayText: text, status: "active", isStarredForSharing: starred ? true : nil, captureKind: .written
            ))
        }

        func complete(_ itemId: String, at date: Date) throws {
            var item = try store.loadItem(id: itemId)
            item.sourceCompletedAt = date
            try store.saveItem(item)
        }

        func access() -> MarginOutputCoordinator.FolderAccess {
            var access = MarginOutputCoordinator.FolderAccess.live
            let live = access.resolve
            let revoked = revoked
            access.resolve = { bookmark in
                if revoked.contains(bookmark) { throw CocoaError(.fileReadNoPermission) }
                let resolved = try live(bookmark)
                return (resolved.url, revoked.refreshed(bookmark) ?? resolved.refreshedBookmark)
            }
            return access
        }

        func bookmark(_ folder: URL) throws -> Data { try MarginOutputCoordinator.FolderAccess.live.makeBookmark(folder) }

        /// A coordinator over the given destinations, saved to a destinations file under the temp root; nil destinations
        /// open whatever file is already there, as a relaunch does.
        func makeCoordinator(_ destinations: [MarginOutputDestination]? = nil, legacy: (() -> MarginOutputMigration.LegacySettings)? = nil) throws -> MarginOutputCoordinator {
            let destinationStore = MarginOutputDestinationStore(fileURL: root.appendingPathComponent("destinations.json"))
            if let destinations { try destinationStore.save(destinations) }
            let store = store
            let journal = root.appendingPathComponent("journal.json")
            return MarginOutputCoordinator(
                store: { store },
                isRecording: { false },
                destinationStore: destinationStore,
                legacy: legacy ?? { MarginOutputMigration.LegacySettings(bookmark: nil, destinationID: nil, isEnabled: false) },
                folders: access(),
                journalURL: { journal }
            )
        }

        func notes(in folder: URL) throws -> [String] {
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" }
                .map { try String(contentsOf: $0, encoding: .utf8) }
        }
    }

    // MARK: - Tests

    func testEachDestinationReceivesOnlyItsScope() async throws {
        let f = try Fixture()
        try f.addMargin("m-plain", text: "A plain thought.")
        try f.addMargin("m-star", text: "A starred thought.", starred: true)
        let everything = try f.folder("Obsidian vault"), starred = try f.folder("Work notes")
        let coordinator = try f.makeCoordinator([
            MarginOutputDestination(id: "all", name: "Obsidian vault", bookmark: try f.bookmark(everything)),
            MarginOutputDestination(id: "star", name: "Work notes", bookmark: try f.bookmark(starred), scope: .starred),
        ])

        await coordinator.pass()

        let all = try f.notes(in: everything), onlyStarred = try f.notes(in: starred)
        XCTAssertEqual(all.count, 2, coordinator.statuses.values.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(onlyStarred.count, 1)
        XCTAssertTrue(onlyStarred[0].contains("A starred thought."))
        XCTAssertFalse(onlyStarred[0].contains("A plain thought."))
        XCTAssertTrue(coordinator.rows.allSatisfy { !$0.needsAccess })
    }

    func testARevokedFolderMarksOnlyThatDestinationAndTheOthersKeepDelivering() async throws {
        let f = try Fixture()
        try f.addMargin("m-1", text: "First.")
        let healthy = try f.folder("Healthy"), lost = try f.folder("Lost")
        let lostBookmark = try f.bookmark(lost)
        let coordinator = try f.makeCoordinator([
            MarginOutputDestination(id: "lost", name: "Lost notes", bookmark: lostBookmark),
            MarginOutputDestination(id: "healthy", name: "Healthy notes", bookmark: try f.bookmark(healthy)),
        ])
        f.revoked.revoke(lostBookmark)

        await coordinator.pass()

        let rows = Dictionary(uniqueKeysWithValues: coordinator.rows.map { ($0.id, $0) })
        XCTAssertEqual(rows["lost"]?.needsAccess, true)
        XCTAssertTrue(rows["lost"]?.status.message.hasPrefix("Needs folder access") == true, rows["lost"]?.status.message ?? "")
        XCTAssertTrue(rows["lost"]?.status.isFailure == true)
        XCTAssertEqual(rows["healthy"]?.needsAccess, false)
        XCTAssertEqual(try f.notes(in: healthy).count, 1, "the other destination must keep delivering")
        XCTAssertEqual(try f.notes(in: lost).count, 0)

        // Reselecting the folder (here the same one, access restored) brings it back with the same id.
        let regained = try f.folder("Regained")
        coordinator.replaceFolder(of: "lost", with: regained)
        XCTAssertEqual(coordinator.destinations.map(\.id), ["lost", "healthy"])
        XCTAssertFalse(coordinator.accessLost.contains("lost"))
        await coordinator.pass()
        XCTAssertEqual(try f.notes(in: regained).count, 1)
        XCTAssertEqual(coordinator.rows.first { $0.id == "lost" }?.needsAccess, false)
    }

    func testAStaleBookmarkIsRefreshedAndTheSamePassStillWritesItsNotes() async throws {
        let f = try Fixture()
        try f.addMargin("m-1", text: "Saved just before switching apps.")
        let folder = try f.folder("Vault")
        let old = try f.bookmark(folder)
        // Distinct bytes, so the saved destination visibly changes; only this one pass resolves it.
        let real = Data("refreshed-bookmark".utf8)
        f.revoked.refresh(old, to: real)
        let coordinator = try f.makeCoordinator([MarginOutputDestination(id: "vault", name: "Vault", bookmark: old)])

        await coordinator.pass()

        XCTAssertEqual(try f.notes(in: folder).count, 1, coordinator.statuses.values.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(coordinator.destinations.first?.bookmark, real, "the refreshed bookmark is saved")
        XCTAssertEqual(coordinator.rows.first?.status.isFailure, false, coordinator.rows.first?.status.message ?? "")
    }

    func testAFolderThatIsGoneNeedsAccessToo() async throws {
        let f = try Fixture()
        try f.addMargin("m-1", text: "First.")
        let gone = try f.folder("Gone")
        let coordinator = try f.makeCoordinator([MarginOutputDestination(id: "gone", name: "Gone", bookmark: try f.bookmark(gone))])
        try FileManager.default.removeItem(at: gone)

        await coordinator.pass()

        XCTAssertEqual(coordinator.rows.first?.needsAccess, true, coordinator.rows.first?.status.message ?? "")
    }

    func testPausingStopsDeliveryAndRemovingKeepsTheFilesAlreadyWritten() async throws {
        let f = try Fixture()
        try f.addMargin("m-1", text: "First.")
        let kept = try f.folder("Kept"), other = try f.folder("Other")
        let coordinator = try f.makeCoordinator([
            MarginOutputDestination(id: "kept", name: "Kept", bookmark: try f.bookmark(kept)),
            MarginOutputDestination(id: "other", name: "Other", bookmark: try f.bookmark(other)),
        ])
        await coordinator.pass()
        XCTAssertEqual(try f.notes(in: kept).count, 1)

        coordinator.setEnabled("kept", false)
        try f.addMargin("m-2", text: "Second.")
        await coordinator.pass()
        XCTAssertEqual(try f.notes(in: kept).count, 1, "a paused destination writes nothing new")
        XCTAssertEqual(try f.notes(in: other).count, 2)
        XCTAssertEqual(coordinator.rows.first { $0.id == "kept" }?.destination.isEnabled, false)

        coordinator.remove("kept")
        XCTAssertEqual(coordinator.destinations.map(\.id), ["other"])
        XCTAssertEqual(try f.notes(in: kept).count, 1, "removing a destination never deletes written notes")
        let relaunched = try f.makeCoordinator(nil)
        XCTAssertEqual(relaunched.destinations.map(\.id), ["other"], "the removal is saved")
    }

    func testATestNoteGoesToAPausedDestinationWithoutStartingDelivery() async throws {
        let f = try Fixture()
        try f.addMargin("m-1", text: "First.")
        let target = try f.folder("Target")
        let coordinator = try f.makeCoordinator([MarginOutputDestination(id: "new", name: "New", bookmark: try f.bookmark(target), isEnabled: false)])

        await coordinator.sendTestNote(to: "new")

        let written = try f.notes(in: target)
        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(written[0].contains("Spoken Margins test"))
        XCTAssertTrue(coordinator.statuses["new"]?.message.hasPrefix("Test note saved") == true, coordinator.statuses["new"]?.message ?? "")
        await coordinator.pass()
        XCTAssertEqual(try f.notes(in: target).count, 1, "the Margin isn't delivered until delivery starts")
    }

    func testAddingADestinationStartsPausedAndKeepsTheFolderName() throws {
        let f = try Fixture()
        let vault = try f.folder("Vault")
        let coordinator = try f.makeCoordinator()

        let first = try XCTUnwrap(coordinator.addDestination(folder: vault))
        let second = try XCTUnwrap(coordinator.addDestination(folder: try f.folder("Vault copy")))

        XCTAssertFalse(first.isEnabled)
        XCTAssertEqual(first.name, "Vault")
        XCTAssertEqual(coordinator.rows.first?.folderName, "Vault")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try f.makeCoordinator(nil).destinations.map(\.id), [first.id, second.id], "both are saved")
        let again = try XCTUnwrap(coordinator.addDestination(folder: vault))
        XCTAssertEqual(again.name, "Vault 2", "a second destination for the same name stays distinguishable")
    }

    func testTodaysSingleFolderIsMigratedWithoutRewritingOrDuplicatingAnyNote() async throws {
        let f = try Fixture()
        try f.addMargin("m-1", text: "Before the update.")
        try f.addMargin("m-2", text: "Also before.")
        let vault = try f.folder("Vault")
        // What the previous build wrote under its one destination id.
        let writer = AutomaticMarginWriter(journalURL: f.root.appendingPathComponent("journal.json"))
        let legacyNotes = try await AutomaticMarginNoteGatherer.gather(store: f.store).notes
        _ = try await writer.deliver(legacyNotes, to: vault, destinationID: "legacy-id")
        let files = try FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        let longAgo = Date(timeIntervalSince1970: 1_600_000_000)
        for file in files { try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: file.path) }
        let before = try files.map { try Data(contentsOf: $0) }
        // One Margin's words changed after that write. Its note is the app's own, so migration must rewrite it in
        // place; under a lost journal id it would be mistaken for a listener edit and kept.
        try f.addMargin("m-1", text: "Reworded after the update.")

        let coordinator = try f.makeCoordinator(nil, legacy: {
            MarginOutputMigration.LegacySettings(bookmark: try? MarginOutputCoordinator.FolderAccess.live.makeBookmark(vault), destinationID: "legacy-id", isEnabled: true)
        })
        XCTAssertEqual(coordinator.destinations.map(\.name), ["Notes folder"])
        XCTAssertEqual(coordinator.destinations.first?.id, "legacy-id")
        await coordinator.pass()

        let after = try FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: [.contentModificationDateKey])
        XCTAssertEqual(after.count, 2, "no duplicate files")
        let texts = try after.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(texts.filter { $0.contains("Reworded after the update.") }.count, 1, "the changed note is rewritten in place")
        XCTAssertFalse(texts.contains { $0.contains("Before the update.") })
        let untouched = try XCTUnwrap(after.first { (try? String(contentsOf: $0, encoding: .utf8))?.contains("Also before.") == true })
        XCTAssertEqual(try Data(contentsOf: untouched), before.first { String(decoding: $0, as: UTF8.self).contains("Also before.") })
        XCTAssertEqual(try untouched.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, longAgo, "an unchanged note was rewritten")
        XCTAssertTrue(coordinator.statuses["legacy-id"]?.message.hasPrefix("2 Margins saved to Notes folder") == true, coordinator.statuses["legacy-id"]?.message ?? "")
    }

    func testChangingWhatNotesHoldRewritesTheNotesThisAppWroteButNotOnesYouEdited() async throws {
        let f = try Fixture()
        try f.addMargin("m-1", text: "Untouched.")
        try f.addMargin("m-2", text: "Edited by me.")
        let vault = try f.folder("Vault")
        let coordinator = try f.makeCoordinator([MarginOutputDestination(id: "v", name: "Vault", bookmark: try f.bookmark(vault))])
        // A pass re-reads what was saved in the 2 seconds before the previous one, so let the Margins age out of that
        // window: then only the destination's changed choice can make the next pass rebuild their notes.
        try await Task.sleep(for: .milliseconds(2_200))
        await coordinator.pass()
        let written = try FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: nil)
        XCTAssertEqual(written.count, 2)
        XCTAssertTrue(try f.notes(in: vault).allSatisfy { $0.contains("## Context before") })
        let edited = try XCTUnwrap(written.first { (try? String(contentsOf: $0, encoding: .utf8))?.contains("Edited by me.") == true })
        try Data("My own words".utf8).write(to: edited)

        coordinator.setContent(of: "v", includesContext: false)
        await coordinator.pass()

        XCTAssertEqual(try String(contentsOf: edited, encoding: .utf8), "My own words")
        let other = try XCTUnwrap(written.first { $0 != edited })
        let rewritten = try String(contentsOf: other, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("Untouched."))
        XCTAssertFalse(rewritten.contains("## Context before"), "the next pass applies the new choice at once, not after the 30 minute repair")
        XCTAssertTrue(coordinator.statuses["v"]?.message.contains("1 note you edited was left as is") == true, coordinator.statuses["v"]?.message ?? "")
    }

    /// #587: one note per item, written when the listener marks it complete. Completing writes no Margin row, so only
    /// the coordinator's hint makes the next pass look at the item.
    func testOneNotePerItemIsWrittenOnCompletionAndRewrittenInPlaceWhenCompletedAgain() async throws {
        let f = try Fixture()
        try f.addMargin("m-1", text: "First thought.")
        try f.addMargin("m-2", text: "Second thought.")
        let vault = try f.folder("Vault")
        let coordinator = try f.makeCoordinator([MarginOutputDestination(
            id: "items", name: "Items", bookmark: try f.bookmark(vault),
            shape: .itemOnCompletion, itemNotesSince: Date(timeIntervalSince1970: 1_700_000_000)
        )])
        try await Task.sleep(for: .milliseconds(2_200)) // Let the Margins age out of the 2 second re-read window.
        await coordinator.pass()
        XCTAssertEqual(try f.notes(in: vault).count, 0, "an item that isn't complete gets no note")

        try f.complete("item-1", at: Date(timeIntervalSince1970: 1_800_000_000))
        coordinator.noteCompletion(ofItem: "item-1")
        await coordinator.pass()
        let first = try f.notes(in: vault)
        XCTAssertEqual(first.count, 1, coordinator.statuses["items"]?.message ?? "")
        let firstNote = try XCTUnwrap(first.first)
        XCTAssertTrue(firstNote.contains("First thought.") && firstNote.contains("Second thought."), "one note holds every Margin")
        XCTAssertTrue(coordinator.statuses["items"]?.message.hasPrefix("1 item note saved to Items") == true, coordinator.statuses["items"]?.message ?? "")

        // Marked unfinished, then complete again later: the same file is rewritten, never a second one.
        try f.complete("item-1", at: Date(timeIntervalSince1970: 1_800_090_000))
        coordinator.noteCompletion(ofItem: "item-1")
        await coordinator.pass()
        let second = try f.notes(in: vault)
        XCTAssertEqual(second.count, 1, "no duplicate")
        XCTAssertNotEqual(second.first, firstNote, "the completion date moved")
    }

    func testChoosingOneNotePerItemSkipsItemsAlreadyFinishedAndEachMarginIsStillTheDefault() async throws {
        let f = try Fixture()
        try f.addMargin("m-1", text: "An old thought.")
        try f.complete("item-1", at: Date(timeIntervalSince1970: 1_700_000_000))
        let vault = try f.folder("Vault")
        let coordinator = try f.makeCoordinator([MarginOutputDestination(id: "d", name: "Vault", bookmark: try f.bookmark(vault))])
        XCTAssertEqual(coordinator.destinations.first?.shape, .eachMargin)

        coordinator.setShape(of: "d", .itemOnCompletion)

        XCTAssertEqual(coordinator.destinations.first?.shape, .itemOnCompletion)
        XCTAssertNotNil(coordinator.destinations.first?.itemNotesSince)
        await coordinator.pass()
        XCTAssertEqual(try f.notes(in: vault).count, 0, "an item finished before the mode was chosen gets no note")
        XCTAssertEqual(try f.makeCoordinator(nil).destinations.first?.shape, .itemOnCompletion, "the choice is saved")
    }

    func testTwoDestinationsOnOneFolderDoNotOverwriteEachOther() async throws {
        let f = try Fixture()
        try f.addMargin("m-1", text: "First.")
        let shared = try f.folder("Shared")
        let coordinator = try f.makeCoordinator([
            MarginOutputDestination(id: "a", name: "Everything", bookmark: try f.bookmark(shared)),
            MarginOutputDestination(id: "b", name: "Context-free", bookmark: try f.bookmark(shared), includesContext: false),
        ])

        await coordinator.pass()

        XCTAssertEqual(try f.notes(in: shared).count, 1)
        XCTAssertTrue(try f.notes(in: shared)[0].contains("## Context before"), "the first destination in the list wins")
        XCTAssertTrue(coordinator.statuses["b"]?.isFailure == true)
        XCTAssertTrue(coordinator.statuses["b"]?.message.contains("Everything already delivers to this folder") == true, coordinator.statuses["b"]?.message ?? "")
    }

    func testAnUnreadableSavedListIsLeftAloneInsteadOfBeingReplaced() throws {
        let f = try Fixture()
        let file = f.root.appendingPathComponent("destinations.json")
        try Data("{ not json".utf8).write(to: file)
        let coordinator = try f.makeCoordinator()

        XCTAssertTrue(coordinator.destinations.isEmpty)
        XCTAssertTrue(coordinator.notice?.isFailure == true)
        XCTAssertNil(coordinator.addDestination(folder: try f.folder("Vault")), "adding must not overwrite a list that couldn't be read")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{ not json")
    }
}
