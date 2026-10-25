import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// The read meter and the Library-shaped fixture (#2258). Everything here uses a real SQLite file.
///
/// Per-run cost: the `small` fixture builds in well under a second. The Library-size checks and the cost table are
/// slower (about 10 s for the Library, more for 3x), so they run only when `SESSIONKIT_READ_COST=1` is set, or
/// `SESSIONKIT_READ_COST_TABLE=<file>` names where to write the table.
final class StoreReadMeterTests: XCTestCase {
    private var fixtures: [LibraryFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
        super.tearDown()
    }

    private func build(_ scale: LibraryFixture.Scale) throws -> LibraryFixture {
        let fixture = try LibraryFixture.build(scale)
        fixtures.append(fixture)
        return fixture
    }

    private var largeScale: Bool { ProcessInfo.processInfo.environment["SESSIONKIT_READ_COST"] == "1" || costTablePath != nil }
    private var costTablePath: String? { ProcessInfo.processInfo.environment["SESSIONKIT_READ_COST_TABLE"] }

    // MARK: The fixture

    func testTheSmallFixtureHasTheShapeOfTheLibrary() throws {
        let scale = LibraryFixture.Scale.small
        let fixture = try build(scale)
        let store = try fixture.openStore()

        XCTAssertEqual(try store.listItems().count, scale.items)
        XCTAssertEqual(try store.loadSessions().count, scale.sessions)
        XCTAssertEqual(try store.loadFeedSubscriptions().count, scale.sources)
        XCTAssertEqual(try store.loadFeedEntries(subscriptionId: nil).count, scale.entries)
        XCTAssertEqual(try store.loadListeningMap(itemId: LibraryFixture.mappedItemId)?.chapters.count, LibraryFixture.mappedSceneCount)
        XCTAssertEqual(try store.loadInterjections(itemId: LibraryFixture.mappedItemId).count, LibraryFixture.mappedMarginCount)
        let timeline = try XCTUnwrap(try store.loadTranscriptTimeline(itemId: LibraryFixture.mappedItemId))
        XCTAssertEqual(timeline.timeline.segments.count, LibraryFixture.mappedDurationMs / LibraryFixture.mappedSegmentMs)
        XCTAssertEqual(try store.loadAudioAssets(itemId: LibraryFixture.mappedItemId).count, 1 + LibraryFixture.mappedSceneCount)
        let titles = try store.listItems().compactMap { $0.text?.utf8.count }
        XCTAssertGreaterThan(titles.max() ?? 0, 1_000_000, "the Library has a book")
        XCTAssertGreaterThan(titles.filter { (20_000...60_000).contains($0) }.count, titles.count / 2, "most articles are 20 to 60 KB")
    }

    func testTheSameSeedGivesTheSameLibrary() throws {
        let first = try build(.small)
        let second = try build(.small)
        // listItems orders by the row's save time (whole seconds), which differs between two builds; compare by id.
        let byId = { (f: LibraryFixture) in try f.openStore().listItems().sorted { $0.id < $1.id } }
        XCTAssertEqual(try byId(first), try byId(second))
    }

    // MARK: The meter

    func testTheMeterCountsRowsBytesAndTheCallingMethod() throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        meter.reset()

        let items = try store.listItems()

        let totals = meter.totals(for: "listItems(includeDeleted:)")
        XCTAssertEqual(totals.calls, 1)
        XCTAssertEqual(totals.rows, items.count)
        let storedBytes = try StoreRawSQL.rows("SELECT SUM(LENGTH(CAST(payload AS BLOB))) FROM records WHERE kind = 'item';",
                                               at: fixture.databaseURL.path)
        XCTAssertEqual(totals.bytes, Int(try XCTUnwrap(storedBytes.first?.first ?? nil)))
        XCTAssertGreaterThan(totals.durationNs, 0)
    }

    func testAPublicReadIsNamedForItselfNotForTheHelperUnderIt() throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        meter.reset()

        _ = try store.loadItem(id: "item-5")
        _ = try store.loadAudioAssets(itemId: LibraryFixture.mappedItemId)
        _ = try store.loadInterjections(sessionId: "session-0")

        XCTAssertEqual(Set(meter.totals().keys), ["loadItem(id:)", "loadAudioAssets(itemId:)", "loadInterjections(sessionId:)"])
        XCTAssertEqual(meter.totals(for: "loadItem(id:)").rows, 1)
        XCTAssertEqual(meter.totals(for: "loadAudioAssets(itemId:)").rows, 1 + LibraryFixture.mappedSceneCount)
    }

    func testTheMeterSeesWhetherAReadRanOnTheMainThread() async throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        meter.reset()

        _ = try await Task.detached { try store.loadSessions() }.value
        XCTAssertEqual(meter.totals(for: "loadSessions()").mainThreadCalls, 0)

        await MainActor.run { _ = try? store.loadSessions() }
        XCTAssertEqual(meter.totals(for: "loadSessions()").mainThreadCalls, 1)
        XCTAssertEqual(meter.totals(for: "loadSessions()").calls, 2)
    }

    func testMeasuringReturnsOnlyTheReadsInsideTheBlock() throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        _ = try store.listItems()

        let (_, samples) = try meter.measuring { try store.loadSessions() }

        XCTAssertEqual(samples.map(\.method), ["loadSessions()"])
    }

    func testAStoreWithoutAMeterRecordsNothingAndReadsTheSame() throws {
        let fixture = try build(.small)
        let plain = try fixture.openStore()
        let meter = StoreReadMeter()
        let metered = try fixture.openStore(meter: meter)
        XCTAssertNil(plain.readMeter)
        XCTAssertEqual(try plain.listItems(), try metered.listItems())
    }

    // MARK: Budgets: the limit a fix has to meet

    /// Reads that are already cheap hold their limit, so a regression fails here.
    func testTheTranscriptSummaryReadsOnlyTheChaptersNotTheSegments() throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        let timelineBytes = try store.sourceTranscriptSizes()[LibraryFixture.mappedItemId] ?? 0
        XCTAssertGreaterThan(timelineBytes, 500_000, "the mapped podcast's timeline is large")
        meter.reset()

        _ = try store.loadTranscriptTimelineSummary(itemId: LibraryFixture.mappedItemId)

        let bytes = meter.samples.reduce(0) { $0 + $1.bytes }
        XCTAssertLessThan(bytes, 20_000, "#2073: the summary must not decode the segments")
    }

    /// The Library list decodes every article's full text. `listItems` is what the Library rows read today (#2102), so
    /// until a summary read exists this is a known-oversized read: the test records the budget and skips with the
    /// measured numbers. When a fix brings the read under the budget the test fails with "remove the marker", so the fix
    /// that lands flips it on purpose (audit step 5, #2256).
    func testTheLibraryListDoesNotDecodeEveryArticleText() throws {
        let scale: LibraryFixture.Scale = largeScale ? .library : .small
        let fixture = try build(scale)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        meter.reset()

        _ = try store.listItems()

        let bytes = meter.totals(for: "listItems(includeDeleted:)").bytes
        // About 1 KB of row metadata per item is plenty for a title, status and dates.
        let budget = scale.items * 1_024
        try expectKnownOversized(bytes > budget, issue: "#2102", message:
            "listItems decoded \(bytes) bytes for \(scale.items) items; a Library row needs under \(budget)")
    }

    private func expectKnownOversized(_ oversized: Bool, issue: String, message: String,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        if oversized { throw XCTSkip("Known oversized read (\(issue)): \(message)") }
        XCTFail("Within budget now: remove expectKnownOversized for \(issue) so the limit is enforced. \(message)", file: file, line: line)
    }

    /// The fixture's mapped podcast has no `media`, so exports treat it as text. A recording's export reads its
    /// timeline for the words around each Margin (#2102); give it the media it has on the phone.
    private func markMappedPodcastAsNativeAudio(_ store: SQLiteSessionStore) throws {
        var item = try store.loadItem(id: LibraryFixture.mappedItemId)
        item.media = ItemMedia(sourceType: .nativeMediaFile, url: "https://cdn.example.com/mapped.mp3", durationMs: LibraryFixture.mappedDurationMs)
        try store.saveItem(item)
    }

    func testSharingAnItemsMarginsAsMarkdownReadsTheItemOncePerSession() throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        try markMappedPodcastAsNativeAudio(store)
        meter.reset()
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store)
        let margins = try store.loadInterjections(itemId: LibraryFixture.mappedItemId).filter(MarginMarkdownShare.hasNote)
        XCTAssertGreaterThan(margins.count, 5, "the mapped podcast has Margins with notes")
        let sessions = Set(margins.map(\.sessionId)).count
        XCTAssertLessThan(sessions, margins.count, "the test only bites when Margins share a session")

        // What it did before: one whole export per Margin, each re-reading the item and the transcript timeline.
        var oneByOne: [(Interjection, String)] = []
        for margin in margins { oneByOne.append((margin, try MarginMarkdownShare.note(for: margin, engine: engine).1)) }
        XCTAssertEqual(meter.totals(for: "loadItem(id:)").calls, margins.count)
        meter.reset()

        let file = try XCTUnwrap(try MarginMarkdownShare.file(forItemMargins: margins, engine: engine))

        XCTAssertEqual(meter.totals(for: "loadItem(id:)").calls, sessions, "the item is read once per session (#2508)")
        XCTAssertEqual(meter.totals(for: "loadTranscriptTimeline(itemId:)").calls, sessions)
        // The notes are the same text the per-Margin exports gave, (sorted, so a dropped or duplicated note shows).
        let expected = oneByOne.map(\.1).filter { !$0.isEmpty }
        XCTAssertEqual(file.markdown.components(separatedBy: MarginMarkdownShare.separator).sorted(), expected.sorted())
    }

    func testAnArticlesMarginNoteDoesNotReadATranscriptTimeline() throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        try markMappedPodcastAsNativeAudio(store)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store)
        let articleIds = Set(try store.listItemSummaries().filter { $0.mediaType == "text" }.map(\.id))
        let notes = try store.loadSessions()
            .flatMap { try store.loadInterjections(sessionId: $0.id) }
            .filter { articleIds.contains($0.itemId) && MarginMarkdownShare.hasNote($0) }
        let margin = try XCTUnwrap(notes.first, "the fixture has a note on an article")
        meter.reset()

        let file = try XCTUnwrap(try MarginMarkdownShare.file(for: margin, engine: engine))

        XCTAssertFalse(file.markdown.isEmpty)
        XCTAssertEqual(meter.totals(for: "loadTranscriptTimeline(itemId:)").calls, 0,
                       "an article's note is cut from the text, so the timeline is never read (#2506)")
        XCTAssertEqual(meter.totals(for: "loadItem(id:)").calls, 1)
        // A recording's note still reads it once, for the words around the Margin.
        let podcastMargin = try XCTUnwrap(try store.loadInterjections(itemId: LibraryFixture.mappedItemId).first(where: MarginMarkdownShare.hasNote))
        meter.reset()
        _ = try MarginMarkdownShare.file(for: podcastMargin, engine: engine)
        XCTAssertEqual(meter.totals(for: "loadTranscriptTimeline(itemId:)").calls, 1)
    }

    func testOneSourcesFeedEntriesReadOnlyThatSourcesRows() throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        let everyEntry = try store.loadFeedEntries(subscriptionId: nil)
        meter.reset()

        let one = try store.loadFeedEntries(subscriptionId: "feed-1")

        XCTAssertEqual(one, everyEntry.filter { $0.subscriptionId == "feed-1" }, "same entries, same order")
        XCTAssertFalse(one.isEmpty)
        XCTAssertLessThan(one.count, everyEntry.count)
        let totals = meter.totals(for: "loadFeedEntries(subscriptionId:)")
        XCTAssertEqual(totals.rows, one.count, "the other sources' rows are not read at all (#2506)")
        XCTAssertEqual(try store.loadFeedEntries(subscriptionId: "no-such-source"), [])
    }

    func testAnItemYesOrNoReadsOneRowNotTheLibrary() throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        meter.reset()

        XCTAssertTrue(try store.hasLiveItem(id: fixture.articleItemId))
        XCTAssertFalse(try store.hasLiveItem(id: "no-such-item"))

        XCTAssertEqual(meter.samples.map(\.method), ["hasLiveItem(id:)", "hasLiveItem(id:)"])
        XCTAssertEqual(meter.samples.map(\.rows), [1, 0], "one row for the item, none for the missing id (#2506)")
        try store.moveItemToTrash(id: fixture.articleItemId)
        XCTAssertFalse(try store.hasLiveItem(id: fixture.articleItemId), "a trashed item is not live, as listItems() said")
    }

    func testOnboardingAsksTheDatabaseForAnActiveMarginInsteadOfReadingEverySession() throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        meter.reset()

        let answer = try store.hasActiveInterjection()
        let asked = meter.totals(for: "hasActiveInterjection()")
        meter.reset()
        let oldAnswer = try store.loadSessions().contains { session in
            try store.loadInterjections(sessionId: session.id).contains { $0.status == "active" }
        }
        let oldBytes = meter.totals().values.reduce(0) { $0 + $1.bytes }

        XCTAssertTrue(answer)
        XCTAssertEqual(answer, oldAnswer)
        XCTAssertEqual(asked.rows, 1, "SQLite stops at the first active Margin (#2506)")
        XCTAssertEqual(asked.bytes, 0, "no payload is copied for a yes or no")
        XCTAssertGreaterThan(oldBytes, 0, "the old scan read every session and Margin it passed")
    }

    func testOneItemsSummaryLeavesItsTextInTheDatabase() throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        meter.reset()

        let summary = try XCTUnwrap(try store.loadItemSummary(id: fixture.articleItemId))
        let summaryRead = meter.totals(for: "loadItemSummary(id:)")
        let whole = try store.loadItem(id: fixture.articleItemId)
        let wholeBytes = whole.text?.utf8.count ?? 0

        XCTAssertEqual(summary, LibraryItemSummary(whole), "the same answer as the whole item gives")
        XCTAssertEqual(summaryRead.rows, 1)
        XCTAssertGreaterThan(wholeBytes, 10_000, "the fixture's article has real text")
        XCTAssertLessThan(summaryRead.bytes, wholeBytes / 4, "the text is cut out in SQLite, not copied and dropped (#2506)")
        XCTAssertNil(try store.loadItemSummary(id: "no-such-item"))
        try store.moveItemToTrash(id: fixture.articleItemId)
        XCTAssertNotNil(try store.loadItemSummary(id: fixture.articleItemId)?.deletedAt, "a trashed item still answers, with its deletedAt")
    }

    func testAnActiveMarginNeedsItsSessionAndAnActiveStatus() throws {
        let fixture = try build(.small)
        let store = try fixture.openStore()
        for session in try store.loadSessions() {
            for var margin in try store.loadInterjections(sessionId: session.id) {
                margin.status = "deleted"
                try store.saveInterjection(margin)
            }
        }
        XCTAssertFalse(try store.hasActiveInterjection(), "only deleted Margins are left")

        var orphan = try XCTUnwrap(try store.loadInterjections(sessionId: "session-0").first)
        orphan.id = "orphan-margin"
        orphan.sessionId = "no-such-session"
        orphan.status = "active"
        try store.saveInterjection(orphan)
        XCTAssertFalse(try store.hasActiveInterjection(), "a Margin whose session is gone never counted")

        orphan.sessionId = "session-0"
        try store.saveInterjection(orphan)
        XCTAssertTrue(try store.hasActiveInterjection())
    }

    func testBatchExportCountsActiveMarginsInTheDatabaseInsteadOfDecodingThem() throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        meter.reset()

        let counts = try store.activeInterjectionCountsBySession()
        let asked = meter.totals(for: "activeInterjectionCountsBySession()")
        meter.reset()
        var oldCounts: [String: Int] = [:]
        for session in try store.loadSessions() {
            let active = try store.loadInterjections(sessionId: session.id).filter { $0.status == "active" }.count
            if active > 0 { oldCounts[session.id] = active }
        }
        let oldBytes = meter.totals().values.reduce(0) { $0 + $1.bytes }

        XCTAssertFalse(counts.isEmpty)
        XCTAssertEqual(counts, oldCounts, "the same counts the per-session read gave (#2506)")
        XCTAssertEqual(asked.bytes, 0, "no Margin payload is copied to count it")
        XCTAssertGreaterThan(oldBytes, 0, "the old count decoded every Margin of every session")

        var margin = try XCTUnwrap(try store.loadInterjections(sessionId: "session-0").first { $0.status == "active" })
        margin.status = "deleted"
        try store.saveInterjection(margin)
        XCTAssertEqual(try store.activeInterjectionCountsBySession()["session-0"] ?? 0, (counts["session-0"] ?? 1) - 1,
                       "a deleted Margin leaves the count")
    }

    func testRecentlyDeletedReadsSummariesInTheOrderOfTheWholeItems() throws {
        let fixture = try build(.small)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        try store.moveItemToTrash(id: fixture.articleItemId, at: early)
        try store.moveItemToTrash(id: LibraryFixture.mappedItemId, at: early.addingTimeInterval(60))
        meter.reset()

        let summaries = try store.listDeletedItemSummaries()
        let summaryRead = meter.totals(for: "listDeletedItemSummaries()")
        meter.reset()
        let whole = try store.listDeletedItems()
        let wholeRead = meter.totals(for: "listItems(includeDeleted:)")

        XCTAssertEqual(summaries.map(\.id), whole.map(\.id), "same members, newest deletion first")
        XCTAssertEqual(summaries.first?.id, LibraryFixture.mappedItemId)
        XCTAssertEqual(summaries, whole.map(LibraryItemSummary.init))
        XCTAssertGreaterThan(wholeRead.bytes, 0)
        XCTAssertLessThan(summaryRead.bytes, wholeRead.bytes / 4, "Recently Deleted no longer copies the trashed articles' text (#2506)")
    }

    /// The screens that only need titles, ids and media types read summaries now. The answers must not change.
    func testSummariesGiveTheSameAnswersAsWholeItems() throws {
        let fixture = try build(.small)
        let store = try fixture.openStore()
        let items = try store.listItems()
        let summaries = try store.listItemSummaries()
        let sessions = try store.loadSessions()

        XCTAssertEqual(OnboardingEvidenceClassifier.sourceSteps(items: items), OnboardingEvidenceClassifier.sourceSteps(items: summaries))
        for startedOnly in [false, true] {
            for query in [nil, "item 1", "ITEM"] as [String?] {
                XCTAssertEqual(
                    StoredSessionMargin.itemChoices(items: items, sessions: sessions, startedOnly: startedOnly, matching: query),
                    StoredSessionMargin.itemChoices(items: summaries, sessions: sessions, startedOnly: startedOnly, matching: query))
            }
        }
    }

    // MARK: Every read is priced (#2513)

    func testTheBackgroundTablesAreSeededAtTheScaleOfTheLibrary() throws {
        let scale = LibraryFixture.Scale.small
        let fixture = try build(scale)
        let store = try fixture.openStore()
        let podcasts = max(1, scale.items / 12)

        XCTAssertEqual(try store.loadPodcastDownloads().count, podcasts)
        XCTAssertFalse(try store.loadPreparedAudioManifests().isEmpty)
        XCTAssertFalse(try store.loadAudioPreparationJobs().isEmpty)
        XCTAssertFalse(try store.loadEpisodeMapPreparationJobs().isEmpty)
        XCTAssertFalse(try store.loadOwnedOfflineAssets().isEmpty)
        XCTAssertFalse(try store.loadOfflineStorageReservations().isEmpty)
        XCTAssertEqual(try store.loadImportedCommentaryLayers().count, max(1, scale.sources / 4))
        XCTAssertEqual(try store.loadSharedMarginTallies().values.reduce(0) { $0 + $1.total }, max(1, scale.sources / 4) * 12)
        XCTAssertFalse(try store.loadStructuredDocumentItemIds().isEmpty)
        XCTAssertNotNil(try store.loadCanonicalSource(itemId: fixture.articleItemId))
        XCTAssertNotNil(try store.loadResolvedListeningMapProjection(itemId: LibraryFixture.mappedItemId))
        XCTAssertFalse(try store.loadPortableListeningMapProposals(itemId: LibraryFixture.mappedItemId).isEmpty)
        // The summaries a Library row needs still match the items: seeding the new tables moved no existing row.
        XCTAssertEqual(try store.listItemSummaries().count, scale.items)
    }

    /// The table is only worth reading if no row of it measures an empty table. These reads are empty in the
    /// fixture on purpose; any other read that decodes no row is a read the fixture does not exercise.
    private static let emptyByDesign: Set<String> = [
        "loadWatchAudioPackage", "loadWatchAudioPackages", "loadWatchSyncEvents", "loadWatchSyncEvent",
        "loadWatchPackageRequests", "hasImportedWatchSyncEvent",   // Apple Watch sync is not shipped
        "quarantinedRecordCount", "quarantinedMarginAudioPaths",   // nothing is quarantined in a healthy Library
        "importedCommentaryRecordsMention",   // a miss is the common answer: it scans every record
        "marginNoteChanges", "itemRevision", "isLiveImportedCommentaryLayer", "transcriptTimelineStamp",
        "listDeletedItems"                    // the trash starts empty
    ]

    /// Answered from memory, not SQLite: nothing for the meter to see.
    private static let inMemory: Set<String> = ["itemRevision"]

    func testEveryReadInTheTableReadsRowsFromSeededTables() throws {
        let fixture = try build(.small)
        let rows = try ReadCostReport.measure(fixture)
        let empty = rows.filter { $0.rows == 0 && !Self.emptyByDesign.contains(Self.baseName($0.read)) }
        XCTAssertEqual(empty.map(\.read), [], "these reads were priced against an empty table; seed it in LibraryFixtureTables")
        let unseen = rows.filter { $0.queries == 0 && !Self.inMemory.contains(Self.baseName($0.read)) }.map(\.read)
        XCTAssertEqual(unseen, [], "the meter did not see these reads; they would price at zero")
    }

    /// Every public read of the store has a row in the table, so a read added later is priced or named here.
    func testEveryPublicReadOfTheStoreIsInTheTable() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SessionKitPersistence")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("SQLiteSessionStore") && $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "the store source moved; update this test")
        let writeVerbs = ["save", "delete", "remove", "update", "apply", "import", "invalidate", "mark", "move", "publish",
                          "restore", "settle", "migrate", "seed", "reset", "sweep", "compose", "plan", "with", "measuring",
                          "totals", "read", "schemaVersion"]
        let regex = try NSRegularExpression(pattern: #"^\s*public func ([A-Za-z0-9_]+)"#, options: [.anchorsMatchLines])
        var reads = Set<String>(), unclassified = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let name = String(text[Range(match.range(at: 1), in: text)!])
                if writeVerbs.contains(where: { name.hasPrefix($0) }) && name != "importedCommentaryRecordsMention" { continue }
                reads.insert(name)
            }
        }
        let tabled = Set(ReadCostReport.reads(try build(.small).openStore(), article: "x").map { Self.baseName($0.name) })
        unclassified = reads.subtracting(tabled)
        XCTAssertEqual(unclassified.sorted(), [], "add a row to ReadCostReport for each new public read (or name it a write above)")
        XCTAssertGreaterThan(reads.count, 50, "the pattern should find the store's reads")
    }

    private static func baseName(_ row: String) -> String { String(row.prefix { $0 != "(" }) }

    // MARK: The cost table

    func testReadCostTableAtEveryScale() throws {
        guard largeScale else { throw XCTSkip("Set SESSIONKIT_READ_COST_TABLE=<file> to build the Library and 3x fixtures and write the table") }
        var report = ReadCostReport()
        for scale in [LibraryFixture.Scale.small, .library, .triple] {
            let fixture = try build(scale)
            report.add(scale: scale, fixture: fixture, rows: try ReadCostReport.measure(fixture))
        }
        let table = report.markdown()
        print(table)
        if let path = costTablePath { try table.write(toFile: path, atomically: true, encoding: .utf8) }
        XCTAssertFalse(table.isEmpty)
    }
}
