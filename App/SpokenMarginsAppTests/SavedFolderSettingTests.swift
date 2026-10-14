import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #930: changing the Export Sessions folder moved the notes folder too, and the notes feature then
/// wrote every Margin (400+ files) into the folder the owner picked for a five-session export.
@MainActor
final class SavedFolderSettingTests: XCTestCase {
    private let keys = [
        "batchExportFolderBookmark", "batchExportFolderName",
        "marginNotesFolderBookmark", "marginNotesFolderName",
        "marginOutputDestinationID",
    ]

    func testChangingTheExportFolderLeavesTheNotesDestinationAlone() throws {
        let defaults = UserDefaults.standard
        let prior = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saved-folder-\(UUID().uuidString)", isDirectory: true)
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        let onMyPhone = root.appendingPathComponent("On My Phone Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: onMyPhone, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            for key in keys {
                if let value = prior[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach(defaults.removeObject(forKey:))

        // The destinations live beside this test database, not in the app's own Application Support folder.
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appendingPathComponent("library.sqlite"))
        let destination = try XCTUnwrap(model.marginOutput.addDestination(folder: vault))
        XCTAssertEqual(model.marginOutput.rows.first?.folderName, "Vault")
        XCTAssertFalse(model.hasBatchExportFolder, "Picking a notes folder must not pick an export folder")

        model.configureBatchExportFolder(url: onMyPhone)

        XCTAssertEqual(model.batchExportFolderName, "On My Phone Exports")
        XCTAssertTrue(model.hasBatchExportFolder)
        XCTAssertEqual(model.marginOutput.destination(destination.id)?.bookmark, destination.bookmark, "The notes folder moved with the export folder")
        XCTAssertEqual(model.marginOutput.destinations.map(\.id), [destination.id], "The destination id is the writer journal key; a new one would rewrite every Margin")
        XCTAssertEqual(model.marginOutput.rows.first?.folderName, "Vault")
    }

    func testFirstLaunchKeepsNotesInTheFolderTheyAlreadyUsed() throws {
        let suite = "saved-folder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([1, 2, 3]), forKey: "batchExportFolderBookmark")
        defaults.set("Spoken export", forKey: "batchExportFolderName")

        XCTAssertTrue(SavedFolderSetting.separateMarginNotesFromSessionExport(defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: "marginNotesFolderBookmark"), Data([1, 2, 3]))
        XCTAssertEqual(defaults.string(forKey: "marginNotesFolderName"), "Spoken export")

        // Later launches never overwrite a notes folder the listener chose.
        defaults.set(Data([9]), forKey: "marginNotesFolderBookmark")
        defaults.set("Vault", forKey: "marginNotesFolderName")
        XCTAssertFalse(SavedFolderSetting.separateMarginNotesFromSessionExport(defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: "marginNotesFolderBookmark"), Data([9]))
        XCTAssertEqual(defaults.string(forKey: "marginNotesFolderName"), "Vault")
    }

    func testSavedFolderResolvesBackToTheSameFolder() throws {
        let suite = "saved-folder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }

        XCTAssertNil(try SavedFolderSetting.marginNotes.resolvedURL(in: defaults))
        try SavedFolderSetting.marginNotes.save(folder: folder, in: defaults)

        XCTAssertEqual(SavedFolderSetting.marginNotes.name(in: defaults), folder.lastPathComponent)
        let resolved = try XCTUnwrap(SavedFolderSetting.marginNotes.resolvedURL(in: defaults))
        XCTAssertEqual(resolved.lastPathComponent, folder.lastPathComponent)
        XCTAssertFalse(SavedFolderSetting.sessionExport.hasFolder(in: defaults))
    }

    func testFirstLaunchWithoutAnExportFolderSetsNoNotesFolder() throws {
        let suite = "saved-folder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(SavedFolderSetting.separateMarginNotesFromSessionExport(defaults: defaults))
        XCTAssertNil(defaults.data(forKey: "marginNotesFolderBookmark"))
    }
}
