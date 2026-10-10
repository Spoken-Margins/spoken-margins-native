import Foundation
import XCTest
@testable import SessionKit

final class LibraryQueryEngineTests: XCTestCase {
    private struct Row: LibraryQueryRow {
        var id: String
        var title = "Title"
        var sourceTitle: String?
        var author: String?
        var mediaType = "text"
        var sourceReference: String?
        var sourceReferenceType: String?
        var isCompleted = false
        var continuationProgressPercent: Int?
        var offlineState: LibraryOfflineStateFilter = .onlineOnly
        var addedAt: Date?
        var lastListenedAt: Date?
        var storageRecencyRank = Int.max
    }

    private let listeningRows = [
        Row(id: "nil"), Row(id: "zero", continuationProgressPercent: 0),
        Row(id: "started", continuationProgressPercent: 1),
        Row(id: "done-zero", isCompleted: true, continuationProgressPercent: 0),
        Row(id: "done-started", isCompleted: true, continuationProgressPercent: 50)
    ]

    private func ids(_ rows: [Row], _ query: LibraryQuery) -> [String] {
        LibraryQueryEngine.visibleLibraryItems(rows, query: query).map(\.id)
    }

    func testUnplayedExcludesCompletedAndProgress() {
        XCTAssertEqual(ids(listeningRows, .init(listeningState: .unplayed)), ["nil", "zero"])
    }

    func testInProgressExcludesCompletedAndZero() {
        XCTAssertEqual(ids(listeningRows, .init(listeningState: .inProgress)), ["started"])
    }

    func testUnfinishedExcludesCompleted() {
        XCTAssertEqual(ids(listeningRows, .init(listeningState: .unfinished)), ["nil", "started", "zero"])
        XCTAssertEqual(ids(listeningRows, .init(listeningState: .completed)), ["done-started", "done-zero"])
        XCTAssertEqual(ids(listeningRows, .init(listeningState: .all)).count, 5)
    }

    func testSearchFoldsCaseAndDiacriticsAcrossMetadata() {
        let rows = [Row(id: "title", title: "CAFÉ"), Row(id: "source", sourceTitle: "Cafe\u{301}"),
                    Row(id: "author", author: "Café"), Row(id: "other", title: "Cafeteria")]
        // Foundation's localized search is exercised on Linux as well as macOS.
        for query in ["café", "  CAFE\n", "cafe\u{301}"] {
            XCTAssertEqual(ids(rows, .init(query: query)), ["author", "other", "source", "title"])
        }
        XCTAssertEqual(ids(rows, .init(query: " ")).count, 4)
        XCTAssertEqual(ids(rows, .init(query: "unrelated")), [])
    }

    func testRecentlyAddedUsesRankOnlyWhenADateIsMissing() {
        let old = Date(timeIntervalSince1970: 10)
        let new = Date(timeIntervalSince1970: 20)
        XCTAssertEqual(ids([Row(id: "dated", addedAt: old, storageRecencyRank: 2),
                            Row(id: "legacy", storageRecencyRank: 1)], .init()), ["legacy", "dated"])
        XCTAssertEqual(ids([Row(id: "legacy", storageRecencyRank: 1),
                            Row(id: "dated", addedAt: old, storageRecencyRank: 1)], .init()), ["dated", "legacy"])
        XCTAssertEqual(ids([Row(id: "old", addedAt: old, storageRecencyRank: 0),
                            Row(id: "new", addedAt: new, storageRecencyRank: 9)], .init()), ["new", "old"])
    }

    func testEverySortBreaksTiesByID() {
        for sort in LibrarySort.allCases {
            XCTAssertEqual(ids([Row(id: "b"), Row(id: "a")], .init(sort: sort)), ["a", "b"])
        }
    }

    func testProgressSortsHighToLowWithMissingAsZero() {
        XCTAssertEqual(ids([Row(id: "zero", continuationProgressPercent: 0), Row(id: "missing"),
                            Row(id: "low", continuationProgressPercent: 1),
                            Row(id: "high", continuationProgressPercent: 90)], .init(sort: .progress)),
                       ["high", "low", "missing", "zero"])
    }

    func testListeningDefaultMigratesAllOnceAndKeepsLaterChoices() {
        let suite = "LibraryQueryEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "libraryListeningStateFilter"
        defaults.set("all", forKey: key)
        XCTAssertEqual(LibraryQueryEngine.loadLibraryListeningFilter(defaults: defaults), .unfinished)
        XCTAssertEqual(defaults.string(forKey: key), "unfinished")
        XCTAssertTrue(defaults.bool(forKey: "libraryUnfinishedDefaultApplied"))
        defaults.set("all", forKey: key)
        XCTAssertEqual(LibraryQueryEngine.loadLibraryListeningFilter(defaults: defaults), .all)
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(LibraryQueryEngine.loadLibraryListeningFilter(defaults: defaults), .unfinished)
        for choice in ["unplayed", "in_progress", "completed", "unfinished"] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(choice, forKey: key)
            XCTAssertEqual(LibraryQueryEngine.loadLibraryListeningFilter(defaults: defaults).rawValue, choice)
        }
        defaults.set("invalid", forKey: key)
        XCTAssertEqual(LibraryQueryEngine.loadLibraryListeningFilter(defaults: defaults), .unfinished)
    }

    func testCaptionsAndPersistedSpellings() throws {
        XCTAssertEqual(LibraryQueryEngine.libraryFilterDescription(query: .init(listeningState: .all)), "All items")
        XCTAssertEqual(LibraryQueryEngine.libraryFilterDescription(query: .init(contentType: .pdf, listeningState: .unplayed)), "PDF · Unplayed")
        XCTAssertEqual(LibraryQueryEngine.libraryFilterDescription(query: .init(contentType: .epub, listeningState: .inProgress, offlineState: .readyOffline)), "EPUB · In Progress · Ready Offline")
        XCTAssertEqual(LibraryQueryEngine.librarySortDescription(query: .init(sort: .recentlyListened)), "Recently Listened")
        XCTAssertEqual(LibraryContentTypeFilter.allCases.map(\.rawValue), ["all", "text", "pdf", "epub", "article", "podcast", "audiobook"])
        XCTAssertEqual(LibraryListeningStateFilter.allCases.map(\.rawValue), ["all", "unfinished", "unplayed", "in_progress", "completed"])
        XCTAssertEqual(LibraryOfflineStateFilter.allCases.map(\.rawValue), ["all", "preparing", "ready_offline", "needs_repreparation", "online_only"])
        XCTAssertEqual(LibrarySort.allCases.map(\.rawValue), ["recently_added", "recently_listened", "title", "progress"])
        // The writer stays app-side. Pin its literal keys without loading the iOS app.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift"), encoding: .utf8)
        for key in ["libraryContentTypeFilter", "libraryListeningStateFilter", "libraryOfflineStateFilter", "librarySort"] {
            XCTAssertTrue(source.contains("forKey: \"\(key)\""), key)
        }
    }

    func testCaughtUpAndHidesCompletedRespectQuery() {
        let rows = [Row(id: "done", isCompleted: true)]
        XCTAssertTrue(LibraryQueryEngine.libraryIsCaughtUp(rows, query: .init()))
        XCTAssertFalse(LibraryQueryEngine.libraryIsCaughtUp([Row](), query: .init()))
        XCTAssertFalse(LibraryQueryEngine.libraryIsCaughtUp(listeningRows, query: .init()))
        for query in [LibraryQuery(query: "word"), .init(contentType: .pdf), .init(listeningState: .completed), .init(offlineState: .readyOffline)] {
            XCTAssertFalse(LibraryQueryEngine.libraryIsCaughtUp(rows, query: query))
        }
        for state in LibraryListeningStateFilter.allCases {
            XCTAssertEqual(LibraryQueryEngine.libraryHidesCompleted(query: .init(listeningState: state)), [.unfinished, .unplayed, .inProgress].contains(state))
        }
    }

    func testContentAndOfflineFiltersIntersect() {
        let rows = [Row(id: "pdf", mediaType: "pdf", offlineState: .readyOffline),
                    Row(id: "url", sourceReference: "https://example.org/file.pdf"), Row(id: "text")]
        XCTAssertEqual(ids(rows, .init(contentType: .pdf)), ["pdf", "url"])
        XCTAssertEqual(ids(rows, .init(contentType: .pdf, offlineState: .readyOffline)), ["pdf"])
        XCTAssertEqual(ids(rows, .init(contentType: .text, offlineState: .readyOffline)), [])
    }

    func testTitleAndRecentlyListenedSort() {
        // Linux Foundation must exercise localizedStandardCompare, including numeric ordering.
        XCTAssertEqual(ids([Row(id: "ten", title: "Part 10"), Row(id: "two", title: "Part 2")], .init(sort: .title)), ["two", "ten"])
        XCTAssertEqual(ids([Row(id: "missing"), Row(id: "old", lastListenedAt: Date(timeIntervalSince1970: 10)),
                            Row(id: "new", lastListenedAt: Date(timeIntervalSince1970: 20))], .init(sort: .recentlyListened)), ["new", "old", "missing"])
    }
}
