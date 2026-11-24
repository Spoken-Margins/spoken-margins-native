import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// #4762: the Library's Filter chip names what narrows the list. It is filled whenever a filter narrows it, the
/// everyday Unfinished view included, reads `Filter` plain only when nothing does, and reads `N Filters` for two or
/// more. It comes from the query alone, so these rows need no store and no rows.
final class LibraryFilterChipStateTests: XCTestCase {
    private func chip(_ query: LibraryQuery) -> LibraryFilterChipState {
        LibraryQueryEngine.libraryFilterChip(query: query)
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "LibraryFilterChipStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Rebuilds the query the way `Gate1AppModel` does at launch; shared Margins is never saved.
    private func relaunchedQuery(_ defaults: UserDefaults) -> LibraryQuery {
        LibraryQuery(
            contentType: LibraryContentTypeFilter(rawValue: defaults.string(forKey: "libraryContentTypeFilter") ?? "") ?? .all,
            listeningState: LibraryQueryEngine.loadLibraryListeningFilter(defaults: defaults),
            offlineState: LibraryOfflineStateFilter(rawValue: defaults.string(forKey: "libraryOfflineStateFilter") ?? "") ?? .all,
            sort: LibrarySort(rawValue: defaults.string(forKey: "librarySort") ?? "") ?? .recentlyAdded
        )
    }

    /// What `Gate1AppModel.libraryQueryChanged` writes, for a listener who already has the Unfinished default.
    private func save(_ query: LibraryQuery, to defaults: UserDefaults) {
        let saved = query.persistedSelection
        defaults.set(saved.contentType.rawValue, forKey: "libraryContentTypeFilter")
        defaults.set(saved.listeningState.rawValue, forKey: "libraryListeningStateFilter")
        defaults.set(saved.offlineState.rawValue, forKey: "libraryOfflineStateFilter")
        defaults.set(saved.sort.rawValue, forKey: "librarySort")
        defaults.set(true, forKey: "libraryUnfinishedDefaultApplied")
    }

    func testTheEverydayViewReadsUnfinishedFilled() {
        XCTAssertEqual(chip(LibraryQuery()), LibraryFilterChipState(isNarrowing: true, title: "Unfinished", accessibilityValue: "Unfinished"))
    }

    func testNothingNarrowingReadsFilterPlain() {
        XCTAssertEqual(chip(LibraryQuery(listeningState: .all)), LibraryFilterChipState(isNarrowing: false, title: "Filter", accessibilityValue: "Everything"))
    }

    func testOneFilterReadsTheMenusOwnWords() {
        for option in LibraryContentTypeFilter.allCases where option != .all {
            let state = chip(LibraryQuery(contentType: option, listeningState: .all))
            XCTAssertEqual(state, LibraryFilterChipState(isNarrowing: true, title: LibraryQueryEngine.displayName(option.rawValue), accessibilityValue: LibraryQueryEngine.displayName(option.rawValue)), option.rawValue)
        }
        for option in LibraryListeningStateFilter.allCases where option != .all {
            XCTAssertEqual(chip(LibraryQuery(listeningState: option)).title, LibraryQueryEngine.displayName(option.rawValue), option.rawValue)
            XCTAssertTrue(chip(LibraryQuery(listeningState: option)).isNarrowing, option.rawValue)
        }
        for option in LibraryOfflineStateFilter.allCases where option != .all {
            XCTAssertEqual(chip(LibraryQuery(listeningState: .all, offlineState: option)).title, LibraryQueryEngine.displayName(option.rawValue), option.rawValue)
        }
        for option in LibrarySharedMarginsFilter.allCases where option != .all {
            XCTAssertEqual(chip(LibraryQuery(listeningState: .all, sharedMargins: option)).title, option.title, option.rawValue)
        }
        // The words the issue and the Design name, spelled out once so a rename of the menu words shows here.
        XCTAssertEqual(chip(LibraryQuery(listeningState: .completed)).title, "Completed")
        XCTAssertEqual(chip(LibraryQuery(listeningState: .inProgress)).title, "In Progress")
        XCTAssertEqual(chip(LibraryQuery(listeningState: .all, offlineState: .needsRepreparation)).title, "Needs Repreparation")
        XCTAssertEqual(chip(LibraryQuery(listeningState: .all, sharedMargins: .newToMe)).title, "New shared Margins")
    }

    func testTwoOrMoreFiltersReadACount() {
        XCTAssertEqual(chip(LibraryQuery(contentType: .pdf)), LibraryFilterChipState(isNarrowing: true, title: "2 Filters", accessibilityValue: "2 filters: PDF, Unfinished"))
        XCTAssertEqual(
            chip(LibraryQuery(contentType: .podcast, listeningState: .inProgress, offlineState: .readyOffline, sharedMargins: .fromOthers)),
            LibraryFilterChipState(isNarrowing: true, title: "4 Filters", accessibilityValue: "4 filters: Podcast, In Progress, Ready Offline, With shared Margins")
        )
        XCTAssertEqual(chip(LibraryQuery(listeningState: .all, offlineState: .preparing, sharedMargins: .newToMe)).title, "2 Filters")
    }

    func testSearchAndSortNeverCount() {
        for sort in LibrarySort.allCases {
            XCTAssertEqual(chip(LibraryQuery(query: "tides", sort: sort)).title, "Unfinished", sort.rawValue)
            XCTAssertEqual(chip(LibraryQuery(query: "  ", listeningState: .all, sort: sort)).isNarrowing, false, sort.rawValue)
        }
    }

    /// Every one of the 7 × 5 × 5 × 3 filter combinations: `Unfinished` shows exactly for the everyday view, the chip
    /// is filled exactly when something narrows, and the count matches the summary line.
    func testEveryCombinationNeverShowsUnfinishedWrongly() {
        var seen = 0
        for content in LibraryContentTypeFilter.allCases {
            for listening in LibraryListeningStateFilter.allCases {
                for offline in LibraryOfflineStateFilter.allCases {
                    for shared in LibrarySharedMarginsFilter.allCases {
                        let query = LibraryQuery(contentType: content, listeningState: listening, offlineState: offline, sharedMargins: shared)
                        let state = chip(query)
                        let label = "\(content.rawValue)/\(listening.rawValue)/\(offline.rawValue)/\(shared.rawValue)"
                        let everyday = listening == .unfinished && content == .all && offline == .all && shared == .all
                        let narrowed = [content == .all, listening == .all, offline == .all, shared == .all].filter { !$0 }.count
                        XCTAssertEqual(state.title == "Unfinished", everyday, label)
                        XCTAssertEqual(state.isNarrowing, narrowed > 0, label)
                        XCTAssertEqual(state.title, narrowed == 0 ? "Filter" : narrowed == 1 ? LibraryQueryEngine.libraryFilterDescription(query: query) : "\(narrowed) Filters", label)
                        seen += 1
                    }
                }
            }
        }
        XCTAssertEqual(seen, 525)
    }

    func testAfterARelaunchTheChipMatchesTheSavedQuery() {
        let rows: [(LibraryQuery, String)] = [
            (LibraryQuery(contentType: .pdf), "2 Filters"),
            (LibraryQuery(listeningState: .unplayed), "Unplayed"),
            // Shared Margins is not saved on purpose, so these lose it after a relaunch.
            (LibraryQuery(listeningState: .all, sharedMargins: .newToMe), "Filter"),
            (LibraryQuery(sharedMargins: .newToMe), "Unfinished"),
            (LibraryQuery(listeningState: .completed, sort: .title), "Completed"),
        ]
        for (query, title) in rows {
            let defaults = freshDefaults()
            save(query, to: defaults)
            XCTAssertEqual(chip(relaunchedQuery(defaults)).title, title, "\(query)")
        }
    }

    func testFirstRunAndReturningListeners() {
        // A fresh install: nothing saved, so the everyday Unfinished view.
        let fresh = freshDefaults()
        XCTAssertEqual(LibraryQueryEngine.loadLibraryListeningFilter(defaults: fresh), .unfinished)
        XCTAssertEqual(chip(relaunchedQuery(freshDefaults())), LibraryFilterChipState(isNarrowing: true, title: "Unfinished", accessibilityValue: "Unfinished"))

        // An upgrade from a build before the Unfinished default (saved `all`, no flag) is migrated to Unfinished.
        let upgrade = freshDefaults()
        upgrade.set("all", forKey: "libraryListeningStateFilter")
        XCTAssertEqual(chip(relaunchedQuery(upgrade)).title, "Unfinished")

        // A returning listener who later chose All keeps it.
        let choseAll = freshDefaults()
        save(LibraryQuery(listeningState: .all), to: choseAll)
        XCTAssertEqual(chip(relaunchedQuery(choseAll)), LibraryFilterChipState(isNarrowing: false, title: "Filter", accessibilityValue: "Everything"))
    }

    /// The view must draw the chip from this function, not from the summary line's `hasActiveFilters`, or the
    /// everyday view goes back to a plain `Filter` chip (the confusion #4762 reports).
    func testTheLibraryScreenDrawsTheChipFromTheQuery() throws {
        let screen = try TestInputs.code(.appSources, "ExperienceLibraryScreen.swift")
        XCTAssertTrue(screen.contains("LibraryQueryEngine.libraryFilterChip(query: model.libraryQuery)"))
        XCTAssertTrue(screen.contains("isActive: chip.isNarrowing"))
        XCTAssertTrue(screen.contains(".accessibilityValue(chip.accessibilityValue)"))
        XCTAssertFalse(screen.contains("Filter Library, active filters"))
        XCTAssertFalse(screen.contains("isActive: hasActiveFilters"))
    }
}
