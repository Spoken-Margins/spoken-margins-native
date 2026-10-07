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

    func testChangingTheExportFolderLeavesTheNotesFolderAndItsDestinationAlone() throws {
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

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.configureMarginNotesFolder(url: vault)
        let notesBookmark = try XCTUnwrap(defaults.data(forKey: "marginNotesFolderBookmark"))
        let destinationID = try XCTUnwrap(defaults.string(forKey: "marginOutputDestinationID"))
        XCTAssertEqual(model.marginNotesFolderName, "Vault")
        XCTAssertFalse(model.hasBatchExportFolder, "Picking the notes folder must not pick an export folder")

        model.configureBatchExportFolder(url: onMyPhone)

        XCTAssertEqual(model.batchExportFolderName, "On My Phone Exports")
        XCTAssertTrue(model.hasBatchExportFolder)
        XCTAssertEqual(defaults.data(forKey: "marginNotesFolderBookmark"), notesBookmark, "The notes folder moved with the export folder")
        XCTAssertEqual(defaults.string(forKey: "marginOutputDestinationID"), destinationID, "A new destination ID makes notes delivery rewrite every Margin")
        XCTAssertEqual(model.marginNotesFolderName, "Vault")
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

    func testFirstLaunchWithoutAnExportFolderSetsNoNotesFolder() throws {
        let suite = "saved-folder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(SavedFolderSetting.separateMarginNotesFromSessionExport(defaults: defaults))
        XCTAssertNil(defaults.data(forKey: "marginNotesFolderBookmark"))
    }
}
