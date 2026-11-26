import XCTest
@testable import SessionKit

/// #3770: every line the app says about a Quick Folder, on a fixed clock, so no surface words a state its own way.
final class QuickFolderStatusTests: XCTestCase {
    /// 2026-09-21 14:13:20 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let iCloudPath = "/private/var/mobile/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault/Clippings"

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func status(
        name: String? = "Clippings", path: String? = nil, checked: TimeInterval? = nil, problem: QuickFolderStatus.Problem? = nil,
        new: Int = 0
    ) -> QuickFolderStatus {
        QuickFolderStatus(
            name: name, path: path, lastCheckedAt: checked.map { now.addingTimeInterval(-$0) }, problem: problem,
            newCount: new, now: now, calendar: calendar,
            locale: Locale(identifier: "en_US"), relative: .english)
    }

    // MARK: "Checked" wording, each band

    func testEachBandOfCheckedWording() {
        let table: [(seconds: TimeInterval, shown: String, spoken: String)] = [
            (0, "Checked just now", "checked just now"),
            (59, "Checked just now", "checked just now"),
            (60, "Checked 1 min. ago", "checked 1 minute ago"),
            (120, "Checked 2 min. ago", "checked 2 minutes ago"),
            (3_599, "Checked 59 min. ago", "checked 59 minutes ago"),
            (3 * 3_600, "Checked 3 hr. ago", "checked 3 hours ago"),
            (86_399, "Checked 23 hr. ago", "checked 23 hours ago"),
            (86_400, "Checked yesterday", "checked yesterday"),
            (3 * 86_400, "Checked 3 days ago", "checked 3 days ago"),
            (7 * 86_400 - 1, "Checked 6 days ago", "checked 6 days ago"),
            (7 * 86_400, "Checked Sep 14", "checked Sep 14"),
            (10 * 86_400, "Checked Sep 11", "checked Sep 11"),
            (400 * 86_400, "Checked Aug 17, 2025", "checked Aug 17, 2025"),
        ]
        for row in table {
            let folder = status(checked: row.seconds)
            XCTAssertEqual(folder.checkedText, row.shown, "\(row.seconds)s")
            XCTAssertEqual(folder.spokenCheckedText, row.spoken, "\(row.seconds)s, spoken")
        }
    }

    func testNeverCheckedAndAClockThatRanBackwards() {
        XCTAssertEqual(status().checkedText, "Not checked yet")
        XCTAssertEqual(status().spokenCheckedText, "Not checked yet")
        XCTAssertEqual(status(checked: -500).checkedText, "Checked just now", "a check stamped in the future")
    }

    func testTheYearShowsOnlyWhenItIsNotThisYear() {
        // "Now" is 2026-01-05 08:00 UTC; ten days earlier is in 2025, and 2 days earlier is this year but under a week.
        let january = Date(timeIntervalSince1970: 1_767_600_000)
        func folder(daysAgo: Double) -> QuickFolderStatus {
            QuickFolderStatus(name: "C", lastCheckedAt: january.addingTimeInterval(-daysAgo * 86_400), now: january,
                              calendar: calendar, locale: Locale(identifier: "en_US"), relative: .english)
        }
        XCTAssertEqual(folder(daysAgo: 10).checkedText, "Checked Dec 26, 2025", "last year: the year is added")
        XCTAssertEqual(folder(daysAgo: 2).checkedText, "Checked 2 days ago")
        // Ten days before 2026-09-21 is this year: no year (the table above).
        XCTAssertEqual(status(checked: 10 * 86_400).checkedText, "Checked Sep 11")
    }

    func testTheScreensLastCheckedValue() {
        XCTAssertEqual(status().lastCheckedValue(isChecking: false), "Not checked yet")
        XCTAssertEqual(status(checked: 5).lastCheckedValue(isChecking: true), "Checking…")
        let value = status(checked: 10 * 86_400).lastCheckedValue(isChecking: false)
        XCTAssertTrue(value.contains("Sep 11, 2026"), value)
        XCTAssertTrue(value.contains("2:13"), "the time of day: \(value)")
    }

    #if canImport(Darwin)
    func testTheSystemFormatterGivesTheNamedAbbreviatedAndFullForms() {
        let locale = Locale(identifier: "en_US")
        let date = now.addingTimeInterval(-120)
        let system = QuickFolderStatus(name: "C", lastCheckedAt: date, now: now, calendar: calendar, locale: locale)
        // Whatever the OS spells it as: the words are the system formatter's, `.named`, abbreviated for the line and full for VoiceOver.
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        let abbreviated = formatter.localizedString(for: date, relativeTo: now)
        formatter.unitsStyle = .full
        let full = formatter.localizedString(for: date, relativeTo: now)
        XCTAssertFalse(abbreviated.isEmpty)
        XCTAssertEqual(system.checkedText, "Checked " + abbreviated)
        XCTAssertEqual(system.spokenCheckedText, "checked " + full)
    }
    #endif

    // MARK: Settings' row

    func testNoFolderChosen() {
        let none = status(name: nil)
        XCTAssertFalse(none.hasFolder)
        XCTAssertEqual(none.displayName, "Quick Folder")
        XCTAssertEqual(none.settingsStatusLine, "None chosen")
        XCTAssertEqual(none.settingsAccessibilityLabel, "Quick Folder, none chosen")
        XCTAssertFalse(none.isListedOnFollowing)
        XCTAssertEqual(status(name: "").settingsStatusLine, "None chosen", "an empty name is no folder")
        XCTAssertNil(status(name: nil, path: iCloudPath).settingsLocationLine, "no folder, no location")
        XCTAssertFalse(status(name: nil, problem: .cantOpen).cantOpen, "nothing to open")
    }

    func testAWorkingFolderSaysNewFilesWaitInFollowing() {
        let waiting = status(path: iCloudPath, checked: 120)
        XCTAssertEqual(QuickFolderStatus.newFilesPhrase, "New files wait in Following")
        XCTAssertEqual(waiting.settingsStatusLine, "Checked 2 min. ago · New files wait in Following")
        XCTAssertEqual(waiting.settingsLocationLine, "Obsidian › Vault › Clippings")
        XCTAssertNil(waiting.settingsStatusSymbol)
        XCTAssertEqual(waiting.settingsAccessibilityLabel,
                       "Quick Folder, Clippings, in Obsidian, Vault, Clippings, checked 2 minutes ago, new files wait in Following")
    }

    func testBeforeTheFirstCheckAndBeforeThePathIsKnown() {
        let fresh = status()
        XCTAssertEqual(fresh.settingsStatusLine, "Not checked yet · New files wait in Following")
        XCTAssertNil(fresh.settingsLocationLine, "line 2 is hidden until the app knows the path")
        XCTAssertEqual(fresh.settingsAccessibilityLabel, "Quick Folder, Clippings, Not checked yet, new files wait in Following")
    }

    func testAFolderThatCantBeOpenedReplacesTheWholeLine() {
        let broken = status(path: iCloudPath, checked: 120, problem: .cantOpen)
        XCTAssertTrue(broken.cantOpen)
        XCTAssertEqual(broken.settingsStatusLine, "Can't open this folder", "no check part, no phrase")
        XCTAssertEqual(broken.settingsStatusSymbol, "exclamationmark.triangle")
        XCTAssertEqual(broken.settingsAccessibilityLabel, "Quick Folder, Clippings, can't open this folder")
        XCTAssertEqual(QuickFolderStatus.cantOpenMessage,
                       "It may have been moved, deleted or signed out, or it may be offline. Check again, or choose it again.")
    }

    /// The words PR 3 puts on screen are fixed here, so no surface can bring the retired queue wording back (#4274).
    func testTheQuickFolderWordsOfferNoPlayQueueMode() {
        XCTAssertEqual(QuickFolderStatus.sectionFooter,
                       "Files you save to a Quick Folder show up in Following, where you choose what to add.")
        XCTAssertEqual(QuickFolderStatus.newFilesFooter,
                       "New files are listed on Following for you to add. Files saved on another device appear once they have synced to this iPhone.")
        XCTAssertEqual(QuickFolderStatus.newFilesPhrase, "New files wait in Following")
        let clippings = status(checked: 120)
        XCTAssertEqual(clippings.settingsStatusLine, "Checked 2 min. ago · New files wait in Following")
        for words in [QuickFolderStatus.sectionFooter, QuickFolderStatus.newFilesFooter, clippings.settingsStatusLine,
                      clippings.settingsAccessibilityLabel] {
            XCTAssertFalse(words.localizedCaseInsensitiveContains("play queue"), words)
        }
    }

    // MARK: The screen

    func testTheScreensValuesAndConfirmation() {
        XCTAssertEqual(status(new: 3).newFilesValue, "3 new")
        XCTAssertEqual(status(new: 1).newFilesValue, "1 new")
        XCTAssertEqual(status(new: 0).newFilesValue, "None new")
        XCTAssertEqual(status(new: -2).newFilesValue, "None new", "a negative count is none")
        XCTAssertEqual(status().removeConfirmationTitle, "Stop importing from “Clippings”?")
        XCTAssertEqual(QuickFolderStatus.removeConfirmationMessage,
                       "Nothing already in your Library or play queue is removed, and the folder's files stay where they are.")
        XCTAssertEqual(QuickFolderStatus.addSheetFootnote, "You can also see and change it in Settings › Import & Export.")
    }

    // MARK: Following

    func testFollowingListsTheFolderWithNewFilesOrAProblem() {
        XCTAssertFalse(status(new: 0).isListedOnFollowing, "nothing new")
        let three = status(new: 3)
        XCTAssertTrue(three.isListedOnFollowing)
        XCTAssertEqual(three.followingTitle, "Clippings")
        XCTAssertEqual(three.followingSubtitle, "Quick Folder · 3 new")
        XCTAssertEqual(three.followingAccessibilityLabel, "Clippings, Quick Folder, 3 new")
        XCTAssertNil(three.followingSymbol)
        let broken = status(problem: .cantOpen, new: 0)
        XCTAssertTrue(broken.isListedOnFollowing, "a silent broken folder is the complaint")
        XCTAssertEqual(broken.followingSubtitle, "Quick Folder · can't open this folder")
        XCTAssertEqual(broken.followingAccessibilityLabel, "Clippings, Quick Folder, can't open this folder")
        XCTAssertEqual(broken.followingSymbol, "exclamationmark.triangle")
    }

    func testFollowingScreenAndCaptions() {
        XCTAssertEqual(status().followingScreenFirstLine, "Quick Folder", "while the location is unknown")
        XCTAssertEqual(status(path: iCloudPath).followingScreenFirstLine, "Quick Folder · Obsidian › Vault › Clippings")
        XCTAssertEqual(status().fileCaption(dateText: "Nov 3"), "Clippings · Nov 3")
    }
}

extension QuickFolderStatus.RelativeText {
    /// The plain English wording, so a table of bands reads the same on every platform.
    static let english = QuickFolderStatus.RelativeText { date, now, spoken, _ in
        QuickFolderStatus.RelativeText.plainEnglish(date: date, now: now, spoken: spoken)
    }
}
