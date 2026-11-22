import Foundation
import XCTest
@testable import SessionKit

/// #930: changing the Export Sessions folder moved the notes folder too, and the notes feature then
/// wrote every Margin (400+ files) into the folder the owner picked for a five-session export.
/// The settings and their migration run on the host (#318); the bookmark and the app's own wiring are
/// still checked in the app's `SavedFolderSettingTests`.
final class SavedFolderSettingHostTests: XCTestCase {
    private func freshDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "saved-folder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    func testTheTwoSettingsKeepTheirOwnKeys() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        SavedFolderSetting.sessionExport.save(bookmark: Data([1]), name: "Exports", in: defaults)

        XCTAssertTrue(SavedFolderSetting.sessionExport.hasFolder(in: defaults))
        XCTAssertEqual(SavedFolderSetting.sessionExport.name(in: defaults), "Exports")
        XCTAssertFalse(SavedFolderSetting.marginNotes.hasFolder(in: defaults), "Picking an export folder must not pick a notes folder")
        XCTAssertNil(SavedFolderSetting.marginNotes.name(in: defaults))

        SavedFolderSetting.marginNotes.save(bookmark: Data([2]), name: "Vault", in: defaults)
        XCTAssertEqual(SavedFolderSetting.sessionExport.bookmark(in: defaults), Data([1]), "Picking a notes folder moved the export folder")
        XCTAssertEqual(SavedFolderSetting.marginNotes.bookmark(in: defaults), Data([2]))
    }

    func testTheKeysAreTheOnesBuildsAlreadyWrote() {
        // A listener's saved folders are read back by key after an update; a renamed key would forget them.
        XCTAssertEqual(SavedFolderSetting.sessionExport.bookmarkKey, "batchExportFolderBookmark")
        XCTAssertEqual(SavedFolderSetting.sessionExport.nameKey, "batchExportFolderName")
        XCTAssertEqual(SavedFolderSetting.marginNotes.bookmarkKey, "marginNotesFolderBookmark")
        XCTAssertEqual(SavedFolderSetting.marginNotes.nameKey, "marginNotesFolderName")
    }

    func testFirstLaunchKeepsNotesInTheFolderTheyAlreadyUsed() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
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
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }

        XCTAssertFalse(SavedFolderSetting.separateMarginNotesFromSessionExport(defaults: defaults))
        XCTAssertNil(defaults.data(forKey: "marginNotesFolderBookmark"))
    }
}
