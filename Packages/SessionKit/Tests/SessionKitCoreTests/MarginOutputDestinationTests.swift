import XCTest
import SessionKit

final class MarginOutputDestinationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("margin-output-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: MarginOutputDestinationStore {
        MarginOutputDestinationStore(fileURL: directory.appendingPathComponent("Nested/MarginOutputDestinations.json"))
    }

    private func destination(
        _ name: String, id: String = UUID().uuidString, scope: MarginOutputDestination.Scope = .all,
        context: Bool = true, text: MarginOutputDestination.TextChoice = .cleaned, enabled: Bool = true
    ) -> MarginOutputDestination {
        .init(id: id, name: name, bookmark: Data(name.utf8), scope: scope, includesContext: context, text: text, isEnabled: enabled)
    }

    // MARK: - Round trip

    func testDestinationsRoundTripInOrderWithEverySetting() throws {
        let saved = [
            destination("Obsidian vault", scope: .starred, context: false, text: .original),
            destination("Work notes", enabled: false),
        ]
        try store.save(saved)
        XCTAssertEqual(try store.load(), saved)
    }

    func testSaveCreatesTheFolderAndReplacesTheFile() throws {
        try store.save([destination("One")])
        try store.save([destination("Two")])
        XCTAssertEqual(try store.load()?.map(\.name), ["Two"])
    }

    func testBookmarkBytesSurviveExactly() throws {
        let bytes = Data((0...255).map { UInt8($0) })
        let saved = [MarginOutputDestination(id: "a", name: "Bytes", bookmark: bytes)]
        try store.save(saved)
        XCTAssertEqual(try store.load()?.first?.bookmark, bytes)
    }

    func testNamesKeepUnicodeWhitespaceAndLength() throws {
        let names = ["Café vault", "  spaced  ", "日本語のノート", "😀 notes", String(repeating: "n", count: 5_000), ""]
        let saved = names.enumerated().map { destination($1, id: "id-\($0)") }
        try store.save(saved)
        XCTAssertEqual(try store.load()?.map(\.name), names)
    }

    func testMissingFileIsNilButEmptyListIsKept() throws {
        XCTAssertNil(try store.load(), "Nothing saved yet: the caller may migrate")
        try store.save([])
        XCTAssertEqual(try store.load(), [], "Removing every destination is a saved choice, not a missing file")
    }

    func testUnreadableFileThrowsInsteadOfBeingTreatedAsEmpty() throws {
        let file = store.fileURL
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try MarginOutputMigration.loadOrMigrate(store: store, legacy: { self.legacy() }),
                             "A damaged file must not be replaced by a migration")
        XCTAssertEqual(try Data(contentsOf: file), Data("not json".utf8))
    }

    func testValueFromANewerBuildLoadsPausedInsteadOfDeliveringMore() throws {
        let json = """
        {"version": 7, "destinations": [{"id": "x", "name": "Future", "bookmark": "AAEC", "scope": "starred-this-week",
        "includesContext": false, "text": "original", "isEnabled": true, "somethingNew": 1}]}
        """
        try write(json)
        let loaded = try XCTUnwrap(try store.load()?.first)
        XCTAssertEqual(loaded.name, "Future")
        XCTAssertEqual(loaded.bookmark, Data([0, 1, 2]))
        XCTAssertEqual(loaded.scope, .all)
        XCTAssertFalse(loaded.includesContext, "Readable fields are kept")
        XCTAssertEqual(loaded.text, .original)
        XCTAssertFalse(loaded.isEnabled, "An unreadable scope must not start delivering everything")
    }

    func testTheNoteShapeRoundTripsAndAnOlderFileMeansEachMargin() throws {
        let since = Date(timeIntervalSince1970: 1_777_000_000)
        let item = MarginOutputDestination(id: "i", name: "Item notes", bookmark: Data([1]), shape: .itemOnCompletion, itemNotesSince: since)
        try store.save([item])
        let loaded = try XCTUnwrap(try store.load()?.first)
        XCTAssertEqual(loaded, item)
        XCTAssertEqual(loaded.content.shape, .itemOnCompletion)
        XCTAssertEqual(loaded.content.itemNotesSince, since)

        try write(#"{"destinations": [{"id": "x", "name": "Older", "bookmark": "AAEC"}]}"#)
        let older = try XCTUnwrap(try store.load()?.first)
        XCTAssertEqual(older.shape, .eachMargin)
        XCTAssertNil(older.itemNotesSince)
        XCTAssertTrue(older.isEnabled)
    }

    func testAShapeFromANewerBuildLoadsPausedInsteadOfGuessing() throws {
        try write(#"{"destinations": [{"id": "x", "name": "Future", "bookmark": "AAEC", "shape": "item_weekly_digest"}]}"#)
        let loaded = try XCTUnwrap(try store.load()?.first)
        XCTAssertEqual(loaded.shape, .eachMargin)
        XCTAssertFalse(loaded.isEnabled)
    }

    func testUnreadableEnabledFlagLoadsPaused() throws {
        try write(#"{"destinations": [{"id": "x", "name": "A", "bookmark": "AAEC", "isEnabled": "paused-until-monday"}]}"#)
        XCTAssertEqual(try store.load()?.first?.isEnabled, false)
    }

    func testOneUnreadableDestinationDoesNotHideTheOthers() throws {
        try write("""
        {"destinations": [{"id": "a", "name": "Good", "bookmark": "AAEC"},
        {"id": "b", "name": "No bookmark"}, 7, {"id": "c", "name": "Also good", "bookmark": "AAEC"}]}
        """)
        XCTAssertEqual(try store.load()?.map(\.id), ["a", "c"])
    }

    private func write(_ json: String) throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.fileURL)
    }

    func testMissingOptionalFieldsTakeTheSingleFolderBehavior() throws {
        let json = #"{"destinations": [{"id": "x", "name": "Bare", "bookmark": "AAEC"}]}"#
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.fileURL)
        XCTAssertEqual(try store.load(), [MarginOutputDestination(id: "x", name: "Bare", bookmark: Data([0, 1, 2]))])
    }

    // MARK: - Migration of today's single folder

    private func legacy(
        bookmark: Data? = Data("bookmark".utf8), id: String? = "journal-id", enabled: Bool = true
    ) -> MarginOutputMigration.LegacySettings {
        .init(bookmark: bookmark, destinationID: id, isEnabled: enabled)
    }

    func testTodaysFolderBecomesOneDestinationWithTheSameBookmarkAndJournalID() throws {
        let migrated = try MarginOutputMigration.loadOrMigrate(store: store, legacy: { self.legacy() })
        XCTAssertEqual(migrated, [MarginOutputDestination(
            id: "journal-id", name: "Notes folder", bookmark: Data("bookmark".utf8),
            scope: .all, includesContext: true, text: .cleaned, isEnabled: true
        )])
        XCTAssertEqual(try store.load(), migrated, "The migration is saved")
    }

    func testMigratedDestinationKeepsTheOnOffChoice() {
        XCTAssertFalse(MarginOutputMigration.destinations(from: legacy(enabled: false))[0].isEnabled)
        XCTAssertTrue(MarginOutputMigration.destinations(from: legacy(enabled: true))[0].isEnabled)
    }

    func testBuildWithNoStoredIDMigratesUnderTheOldFallbackKey() {
        // The old code keyed its journal on "initial" when no ID was stored; a different key would rewrite every note.
        XCTAssertEqual(MarginOutputMigration.destinations(from: legacy(id: nil))[0].id, "initial")
        XCTAssertEqual(MarginOutputMigration.fallbackDestinationID, "initial")
    }

    func testNoFolderMeansNoDestination() {
        XCTAssertEqual(MarginOutputMigration.destinations(from: legacy(bookmark: nil)), [])
        XCTAssertEqual(MarginOutputMigration.destinations(from: legacy(bookmark: Data())), [])
        XCTAssertEqual(MarginOutputMigration.destinations(from: legacy(bookmark: nil, id: "kept", enabled: true)), [])
    }

    func testMigrationRunsOnceAndNeverRereadsTheOldKeys() throws {
        var reads = 0
        let first = try MarginOutputMigration.loadOrMigrate(store: store, legacy: { reads += 1; return self.legacy() })
        let second = try MarginOutputMigration.loadOrMigrate(store: store, legacy: { reads += 1; return self.legacy(bookmark: Data("other".utf8), id: "other") })
        XCTAssertEqual(first, second)
        XCTAssertEqual(reads, 1)
    }

    func testRemovingTheMigratedDestinationIsNotUndoneByTheNextLaunch() throws {
        _ = try MarginOutputMigration.loadOrMigrate(store: store, legacy: { self.legacy() })
        try store.save([])
        XCTAssertEqual(try MarginOutputMigration.loadOrMigrate(store: store, legacy: { self.legacy() }), [])
    }

    func testNoFolderIsSavedSoALaterLaunchDoesNotMigrateAFolderPickedElsewhere() throws {
        XCTAssertEqual(try MarginOutputMigration.loadOrMigrate(store: store, legacy: { self.legacy(bookmark: nil) }), [])
        XCTAssertEqual(try MarginOutputMigration.loadOrMigrate(store: store, legacy: { self.legacy() }), [])
    }

    // MARK: - Naming

    func testNextNameSkipsTakenNamesIgnoringCase() {
        XCTAssertEqual(MarginOutputDestination.nextName(existing: []), "Notes folder")
        let one = destination("Notes folder")
        XCTAssertEqual(MarginOutputDestination.nextName(existing: [one]), "Notes folder 2")
        XCTAssertEqual(MarginOutputDestination.nextName(existing: [one, destination("notes FOLDER 2")]), "Notes folder 3")
        XCTAssertEqual(MarginOutputDestination.nextName(existing: [destination("Work notes")]), "Notes folder")
        XCTAssertEqual(MarginOutputDestination.nextName(base: "Vault", existing: [destination("Vault")]), "Vault 2")
    }
}
