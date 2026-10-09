import XCTest
@testable import SessionKit

/// #955: the Quick Add list on the Following tab (Quick Folder files plus followed episodes) and the
/// Quick Folder scan moved out of Gate1AppModel. These tests pin the rules the move must not change.
final class QuickAddFeedTests: XCTestCase {
    private func file(_ id: String, modifiedAt: TimeInterval) -> QuickAccessFile {
        QuickAccessFile(
            id: id,
            name: (id as NSString).deletingPathExtension,
            relativePath: id,
            modifiedAt: Date(timeIntervalSince1970: modifiedAt),
            modifiedAtDescription: "then"
        )
    }

    private func entry(
        _ id: String,
        title: String = "An Episode",
        url: String? = nil,
        subscription: String = "show",
        publishedAt: TimeInterval? = nil
    ) -> FeedEntry {
        FeedEntry(
            id: id,
            subscriptionId: subscription,
            canonicalURL: url ?? "https://example.com/\(id)",
            title: title,
            publishedAt: publishedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func subscription(_ id: String = "show", title: String? = "The Show") -> FeedSubscription {
        FeedSubscription(
            id: id,
            source: SourceIdentity(
                id: "source-\(id)",
                kind: .podcastFeed,
                canonicalURL: "https://example.com/\(id).xml",
                host: "example.com",
                title: title
            )
        )
    }

    // MARK: Feed rules

    func testFolderFilesAndFollowedEntriesMergeNewestFirst() {
        let candidates = QuickAddFeed.candidates(
            folderFiles: [file("older.md", modifiedAt: 100)],
            followedEntries: [entry("episode", title: "New Episode", publishedAt: 200)]
        )
        XCTAssertEqual(candidates.map(\.id), ["followed-source:episode", "local-file:older.md"])
    }

    func testSortTiesBreakByIdAscendingAcrossFilesAndEntries() {
        let candidates = QuickAddFeed.candidates(
            folderFiles: [file("b.md", modifiedAt: 100), file("a.md", modifiedAt: 100), file("z.md", modifiedAt: 300)],
            followedEntries: [entry("m", publishedAt: 100), entry("k", publishedAt: 100)]
        )
        XCTAssertEqual(candidates.map(\.id), [
            "local-file:z.md",
            "followed-source:k",
            "followed-source:m",
            "local-file:a.md",
            "local-file:b.md"
        ])
    }

    func testAnEntryWithoutAPublishDateSortsAfterEveryDatedItem() {
        let candidates = QuickAddFeed.candidates(
            folderFiles: [file("old.md", modifiedAt: 1)],
            followedEntries: [entry("undated"), entry("dated", publishedAt: 5)]
        )
        XCTAssertEqual(candidates.map(\.id), ["followed-source:dated", "local-file:old.md", "followed-source:undated"])
    }

    func testCandidateIdsKeepTheirPrefixes() {
        let local = QuickAddCandidate.localFile(file("notes.md", modifiedAt: 1))
        let followed = QuickAddCandidate.followedSource(entry("episode"))
        XCTAssertEqual(local.id, "local-file:notes.md")
        XCTAssertEqual(followed.id, "followed-source:episode")
    }

    func testDismissalKeyIsTheIdAndWholeSecondsOfTheModifiedDate() {
        XCTAssertEqual(file("notes.md", modifiedAt: 100).dismissalKey, "notes.md|100")
        // Fractions of a second are dropped, as Build 29 stored them.
        XCTAssertEqual(file("notes.md", modifiedAt: 100.9).dismissalKey, "notes.md|100")
        XCTAssertEqual(file("notes.md", modifiedAt: 0).dismissalKey, "notes.md|0")
    }

    func testADismissedFileRevisionIsHiddenAndALaterRevisionIsNot() {
        let dismissed: Set<String> = ["notes.md|100"]
        let hidden = QuickAddFeed.candidates(
            folderFiles: [file("notes.md", modifiedAt: 100)],
            followedEntries: [],
            dismissedFileKeys: dismissed
        )
        XCTAssertTrue(hidden.isEmpty)
        let edited = QuickAddFeed.candidates(
            folderFiles: [file("notes.md", modifiedAt: 101), file("other.md", modifiedAt: 100)],
            followedEntries: [],
            dismissedFileKeys: dismissed
        )
        // Newest first: the edited notes.md (101), then other.md (100).
        XCTAssertEqual(edited.map(\.id), ["local-file:notes.md", "local-file:other.md"])
    }

    func testAnEntryWhoseNormalizedURLMatchesALibraryItemIsHidden() {
        let imported = QuickAddImportedItem(
            sourceReference: "HTTPS://Example.com/posts/one/#comments",
            title: "Something else entirely",
            sourceTitle: nil
        )
        let candidates = QuickAddFeed.candidates(
            folderFiles: [],
            followedEntries: [
                entry("hidden", title: "Unrelated title", url: "https://example.com/posts/one"),
                entry("kept", title: "Another", url: "https://example.com/posts/two")
            ],
            libraryItems: [imported]
        )
        XCTAssertEqual(candidates.map(\.id), ["followed-source:kept"])
    }

    func testAnEntryWithTheSameShowAndEpisodeKeyAsALibraryItemIsHidden() {
        let imported = QuickAddImportedItem(
            sourceReference: "https://podcasts.apple.com/episode",
            title: "ALREADY heard!",
            sourceTitle: "the show"
        )
        let candidates = QuickAddFeed.candidates(
            folderFiles: [],
            followedEntries: [
                entry("hidden", title: "Already Heard", url: "https://example.com/feed-entry"),
                entry("kept", title: "Not Yet Heard", url: "https://example.com/feed-entry-2")
            ],
            subscriptions: [subscription()],
            libraryItems: [imported]
        )
        XCTAssertEqual(candidates.map(\.id), ["followed-source:kept"])
    }

    func testTheSameEpisodeTitleFromADifferentShowIsNotHidden() {
        let imported = QuickAddImportedItem(sourceReference: nil, title: "Already Heard", sourceTitle: "Another Show")
        let candidates = QuickAddFeed.candidates(
            folderFiles: [],
            followedEntries: [entry("kept", title: "Already Heard")],
            subscriptions: [subscription(title: "The Show")],
            libraryItems: [imported]
        )
        XCTAssertEqual(candidates.map(\.id), ["followed-source:kept"])
    }

    func testAShowWithoutATitleIsKeyedByItsHost() {
        let imported = QuickAddImportedItem(sourceReference: nil, title: "Already Heard", sourceTitle: "example.com")
        let candidates = QuickAddFeed.candidates(
            folderFiles: [],
            followedEntries: [entry("hidden", title: "Already Heard")],
            subscriptions: [subscription(title: nil)],
            libraryItems: [imported]
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testImportedLibraryItemsNeverHideFolderFiles() {
        let imported = QuickAddImportedItem(sourceReference: "notes.md", title: "notes", sourceTitle: nil)
        let candidates = QuickAddFeed.candidates(
            folderFiles: [file("notes.md", modifiedAt: 1)],
            followedEntries: [],
            libraryItems: [imported]
        )
        XCTAssertEqual(candidates.map(\.id), ["local-file:notes.md"])
    }

    // MARK: URL rule (copied as is; see the note on QuickAddFeed.normalizedURL)

    func testNormalizedURLTable() {
        let table: [(String?, String?)] = [
            ("https://example.com/a", "https://example.com/a"),
            ("HTTPS://EXAMPLE.COM/a", "https://example.com/a"),
            ("http://Example.com/a", "http://example.com/a"),
            // Path and query keep their case.
            ("https://example.com/Path/To/Page", "https://example.com/Path/To/Page"),
            ("https://example.com/a?Q=Mixed", "https://example.com/a?Q=Mixed"),
            // Fragment dropped.
            ("https://example.com/a#section", "https://example.com/a"),
            ("https://example.com/a?x=1#section", "https://example.com/a?x=1"),
            // One trailing slash removed; a bare root stays.
            ("https://example.com/a/", "https://example.com/a"),
            ("https://example.com/a//", "https://example.com/a/"),
            ("https://example.com/a/?x=1", "https://example.com/a?x=1"),
            ("https://example.com/", "https://example.com/"),
            ("https://example.com", "https://example.com"),
            // Port kept.
            ("https://Example.com:8080/a/", "https://example.com:8080/a"),
            // Surrounding whitespace trimmed.
            ("  https://example.com/a \n", "https://example.com/a"),
            // Only http and https, with a host.
            ("ftp://example.com/a", nil),
            ("file:///Documents/paper.pdf", nil),
            ("mailto:someone@example.com", nil),
            ("example.com/a", nil),
            ("https:/no/host/here", nil),
            ("https:", nil),
            ("/relative/path", nil),
            ("", nil),
            ("   ", nil),
            (nil, nil)
        ]
        for (input, expected) in table {
            XCTAssertEqual(QuickAddFeed.normalizedURL(input), expected, "input: \(String(describing: input))")
        }
    }

    func testNormalizedURLMakesWWWAndSchemeVariantsDistinct() {
        // Lookalike sources are different on purpose: only scheme case, host case, fragment and one
        // trailing slash are folded. Anything more would hide episodes the listener hasn't imported.
        let base = QuickAddFeed.normalizedURL("https://example.com/a")
        XCTAssertNotEqual(base, QuickAddFeed.normalizedURL("https://www.example.com/a"))
        XCTAssertNotEqual(base, QuickAddFeed.normalizedURL("http://example.com/a"))
        XCTAssertNotEqual(base, QuickAddFeed.normalizedURL("https://example.com/a?utm_source=x"))
    }

    func testNormalizedURLHandlesAVeryLongPath() {
        let path = String(repeating: "segment/", count: 2_000)
        let normalized = QuickAddFeed.normalizedURL("https://example.com/\(path)")
        XCTAssertEqual(normalized, "https://example.com/" + String(path.dropLast()))
    }

    // MARK: Episode key rule (copied as is; see the note on QuickAddFeed.episodeKey)

    func testEpisodeKeyTable() {
        let table: [(title: String, show: String?, key: String)] = [
            ("Already Heard", "The Show", "the show|already heard"),
            // Case.
            ("ALREADY HEARD", "THE SHOW", "the show|already heard"),
            // Whitespace and punctuation are separators, runs collapse, ends are trimmed.
            ("  Already   Heard!! ", "The  Show", "the show|already heard"),
            ("Already-Heard: Part 2 (Live)", "The Show", "the show|already heard part 2 live"),
            // Digits are kept.
            ("Episode 10", "The Show", "the show|episode 10"),
            // Diacritics fold to their base letter.
            ("Café Épisode", "Théâtre", "theatre|cafe episode"),
            ("Ünïcödé", nil, "|unicode"),
            // Letters with no ASCII base become separators instead of being kept.
            ("日本語 News", nil, "|news"),
            ("Episode №5", nil, "|episode 5"),
            ("Привет", nil, "|"),
            // A missing show title and an empty one are the same.
            ("Already Heard", nil, "|already heard"),
            ("Already Heard", "", "|already heard"),
            // Empty.
            ("", nil, "|"),
            ("!!!", "???", "|")
        ]
        for row in table {
            XCTAssertEqual(
                QuickAddFeed.episodeKey(title: row.title, sourceTitle: row.show),
                row.key,
                "title: \(row.title), show: \(String(describing: row.show))"
            )
        }
    }

    func testEpisodeKeysOfNeighbouringEpisodesDiffer() {
        XCTAssertNotEqual(
            QuickAddFeed.episodeKey(title: "Episode 1", sourceTitle: "The Show"),
            QuickAddFeed.episodeKey(title: "Episode 10", sourceTitle: "The Show")
        )
        XCTAssertNotEqual(
            QuickAddFeed.episodeKey(title: "Episode 1", sourceTitle: "The Show"),
            QuickAddFeed.episodeKey(title: "Episode 1", sourceTitle: "The Shows")
        )
    }

    func testEpisodeKeyOfAVeryLongTitleIsStable() {
        let title = String(repeating: "Long Title ", count: 2_000)
        let key = QuickAddFeed.episodeKey(title: title, sourceTitle: "The Show")
        XCTAssertEqual(key, QuickAddFeed.episodeKey(title: title.uppercased(), sourceTitle: "the show"))
        XCTAssertTrue(key.hasPrefix("the show|long title long title"))
        XCTAssertFalse(key.hasSuffix(" "))
    }

    // MARK: Folder scan

    private func makeFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-quick-add-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func write(_ name: String, in directory: URL, modifiedAt: TimeInterval? = nil) throws {
        let url = directory.appendingPathComponent(name)
        try "content".write(to: url, atomically: true, encoding: .utf8)
        if let modifiedAt {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: modifiedAt)],
                ofItemAtPath: url.path
            )
        }
    }

    func testScanOffersOnlyImportableTextAndPDFFiles() throws {
        let directory = try makeFolder()
        for name in ["Notes.md", "Draft.markdown", "Excerpt.txt", "Paper.pdf", "Cover.jpg", "Archive.zip", "NoExtension", "Page.html"] {
            try write(name, in: directory)
        }
        let scan = QuickAccessFolderScanner.scan(directory)
        XCTAssertNil(scan.errorDescription)
        XCTAssertEqual(Set(scan.files.map(\.relativePath)), ["Notes.md", "Draft.markdown", "Excerpt.txt", "Paper.pdf"])
    }

    func testScanMatchesExtensionsCaseInsensitivelyAndKeepsTheFileNameAsId() throws {
        let directory = try makeFolder()
        try write("SHOUT.MD", in: directory)
        try write("Mixed.Pdf", in: directory)
        let scan = QuickAccessFolderScanner.scan(directory)
        XCTAssertEqual(Set(scan.files.map(\.id)), ["SHOUT.MD", "Mixed.Pdf"])
        let shout = try XCTUnwrap(scan.files.first { $0.id == "SHOUT.MD" })
        XCTAssertEqual(shout.name, "SHOUT")
        XCTAssertEqual(shout.relativePath, "SHOUT.MD")
    }

    func testScanSkipsHiddenFilesAndFolders() throws {
        let directory = try makeFolder()
        try write("Visible.md", in: directory)
        try write(".Hidden.md", in: directory)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Folder.md", isDirectory: true),
            withIntermediateDirectories: false
        )
        let scan = QuickAccessFolderScanner.scan(directory)
        XCTAssertNil(scan.errorDescription)
        XCTAssertEqual(scan.files.map(\.relativePath), ["Visible.md"])
    }

    func testScanReturnsAtMostEightFilesNewestFirst() throws {
        let directory = try makeFolder()
        for index in 0..<10 {
            try write("note-\(index).md", in: directory, modifiedAt: 1_000 + Double(index) * 10)
        }
        let scan = QuickAccessFolderScanner.scan(directory)
        XCTAssertNil(scan.errorDescription)
        XCTAssertEqual(scan.files.map(\.id), (2..<10).reversed().map { "note-\($0).md" })
        XCTAssertEqual(scan.files.first?.modifiedAt, Date(timeIntervalSince1970: 1_090))
    }

    func testScanOfAnUnreadableFolderReportsTheErrorAndNoFiles() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-quick-add-missing-\(UUID().uuidString)", isDirectory: true)
        let scan = QuickAccessFolderScanner.scan(missing)
        XCTAssertTrue(scan.files.isEmpty)
        XCTAssertFalse(try XCTUnwrap(scan.errorDescription).isEmpty)
    }

    func testScanOfAnEmptyFolderIsEmptyWithoutAnError() throws {
        let scan = QuickAccessFolderScanner.scan(try makeFolder())
        XCTAssertTrue(scan.files.isEmpty)
        XCTAssertNil(scan.errorDescription)
    }
}
