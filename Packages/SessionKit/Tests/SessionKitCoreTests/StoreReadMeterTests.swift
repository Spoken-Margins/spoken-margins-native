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
