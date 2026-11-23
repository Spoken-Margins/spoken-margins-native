import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #3770 PR 3: Settings, Following and the Add sheet word the Quick Folder from `QuickAccessFolderState.status()`, built
/// from what the state remembers in its defaults. These seed a scratch suite with the stored keys, as an earlier build or a
/// finished scan left them, and read the words a listener sees. No folder is scanned and no bookmark is resolved.
@MainActor
final class QuickFolderSettingsStatusTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "QuickFolderSettingsStatusTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func state() -> QuickAccessFolderState { QuickAccessFolderState(defaults: defaults) }

    /// No folder ever chosen: Settings says "None chosen" and Following lists nothing.
    func testNoFolderReadsNoneChosenAndIsNotOnFollowing() {
        let status = state().status()
        XCTAssertFalse(status.hasFolder)
        XCTAssertEqual(status.settingsStatusLine, "None chosen")
        XCTAssertEqual(status.settingsAccessibilityLabel, "Quick Folder, none chosen")
        XCTAssertNil(status.settingsLocationLine)
        XCTAssertFalse(status.isListedOnFollowing)
    }

    /// An upgrade from a build that stored only the bookmark and the name: the name shows, the location stays hidden until a
    /// scan learns it, and new files wait in Following.
    func testAnUpgradedFolderShowsItsNameAndNotCheckedYet() {
        defaults.set(Data([1, 2, 3]), forKey: QuickAccessFolderState.folderBookmarkKey)
        defaults.set("Clippings", forKey: QuickAccessFolderState.folderNameKey)
        let status = state().status()
        XCTAssertEqual(status.displayName, "Clippings")
        XCTAssertNil(status.settingsLocationLine)
        XCTAssertEqual(status.settingsStatusLine, "Not checked yet · New files wait in Following")
        XCTAssertNil(status.settingsStatusSymbol)
    }

    /// A folder a scan has seen: the location line, and a check time with the one new-files phrase.
    func testACheckedFolderShowsWhereItIsAndWhenItWasChecked() {
        let now = Date()
        defaults.set(Data([1, 2, 3]), forKey: QuickAccessFolderState.folderBookmarkKey)
        defaults.set("Clippings", forKey: QuickAccessFolderState.folderNameKey)
        defaults.set(
            "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Obsidian/Clippings",
            forKey: QuickAccessFolderState.folderPathKey)
        defaults.set(now.addingTimeInterval(-120), forKey: QuickAccessFolderState.lastCheckedAtKey)
        let status = state().status(newCount: 3, now: now)
        XCTAssertEqual(status.settingsLocationLine, "iCloud Drive › Obsidian › Clippings")
        XCTAssertTrue(status.settingsStatusLine.hasPrefix("Checked "), status.settingsStatusLine)
        XCTAssertTrue(status.settingsStatusLine.hasSuffix(" · New files wait in Following"), status.settingsStatusLine)
        XCTAssertFalse(status.settingsStatusLine.contains("play queue"))
        XCTAssertEqual(status.followingTitle, "Clippings")
        XCTAssertEqual(status.followingSubtitle, "Quick Folder · 3 new")
        XCTAssertEqual(status.followingScreenFirstLine, "Quick Folder · iCloud Drive › Obsidian › Clippings")
        XCTAssertEqual(status.fileCaption(dateText: "2 hr. ago"), "Clippings · 2 hr. ago")
    }

    /// A folder that can't be opened: the warning replaces line 3, with its icon, and Following lists the folder even with no
    /// new files.
    func testAFolderThatCantBeOpenedSaysSoOnSettingsAndFollowing() {
        defaults.set(Data([1, 2, 3]), forKey: QuickAccessFolderState.folderBookmarkKey)
        defaults.set("Clippings", forKey: QuickAccessFolderState.folderNameKey)
        defaults.set(QuickFolderStatus.Problem.cantOpen.rawValue, forKey: QuickAccessFolderState.folderProblemKey)
        let status = state().status()
        XCTAssertEqual(status.settingsStatusLine, "Can't open this folder")
        XCTAssertEqual(status.settingsStatusSymbol, "exclamationmark.triangle")
        XCTAssertEqual(status.settingsAccessibilityLabel, "Quick Folder, Clippings, can't open this folder")
        XCTAssertTrue(status.isListedOnFollowing)
        XCTAssertEqual(status.followingSubtitle, "Quick Folder · can't open this folder")
    }

    /// Removing the folder goes back to "None chosen" and keeps the dismissed files, so they don't come back if it is chosen again.
    func testRemovingTheFolderGoesBackToNoneChosen() {
        defaults.set(Data([1, 2, 3]), forKey: QuickAccessFolderState.folderBookmarkKey)
        defaults.set("Clippings", forKey: QuickAccessFolderState.folderNameKey)
        defaults.set("/x/Clippings", forKey: QuickAccessFolderState.folderPathKey)
        defaults.set(Date(), forKey: QuickAccessFolderState.lastCheckedAtKey)
        defaults.set(QuickFolderStatus.Problem.cantOpen.rawValue, forKey: QuickAccessFolderState.folderProblemKey)
        defaults.set(["a"], forKey: QuickAccessFolderState.dismissedFilesKey)
        let state = state()
        XCTAssertTrue(state.status().cantOpen)
        state.remove()
        let status = state.status()
        XCTAssertEqual(status.settingsStatusLine, "None chosen")
        XCTAssertNil(status.path)
        XCTAssertNil(status.lastCheckedAt)
        XCTAssertNil(status.problem)
        XCTAssertFalse(status.isListedOnFollowing)
        XCTAssertEqual(state.dismissedFileKeys, ["a"])
    }
}
