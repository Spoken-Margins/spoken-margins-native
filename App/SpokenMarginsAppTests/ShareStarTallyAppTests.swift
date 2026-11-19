import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #4173 PR 2: the counts and the `share.selection` Diagnostics line. The tally lives in `UserDefaults`, so each test starts
/// and ends with it empty.
@MainActor
final class ShareStarTallyAppTests: XCTestCase {
    private struct Fixture {
        let model: Gate1AppModel
        let store: SQLiteSessionStore
        let itemId: String
        let sessionId: String
        let root: URL
    }

    override func setUp() {
        super.setUp()
        ShareStarTallyStore().reset()
    }

    override func tearDown() {
        ShareStarTallyStore().reset()
        super.tearDown()
    }

    private func makeFixture(margins: [String]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "share-star-tally-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        model.resetAndSeed()
        let itemId = model.selectedItem.id
        model.startItem(id: itemId)
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        let store = try SQLiteSessionStore(path: url.path)
        for id in margins { try store.saveInterjection(margin(id: id, itemId: itemId, sessionId: sessionId)) }
        model.openItem(id: itemId)
        return Fixture(model: model, store: store, itemId: itemId, sessionId: sessionId, root: root)
    }

    private func margin(id: String, itemId: String, sessionId: String) -> Interjection {
        Interjection(
            id: id, itemId: itemId, sessionId: sessionId, targetType: .item, targetId: itemId,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 50,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 5, anchorBefore: "Before", anchorAfter: "After"),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
            transcript: "Words nobody should find in Diagnostics.", cleanedTranscript: nil, displayText: nil, status: "active"
        )
    }

    private func shown(_ fixture: Fixture, _ id: String) throws -> Interjection {
        try XCTUnwrap(fixture.model.selectedItem.interjections.first { $0.id == id })
    }

    func testTheSetterCountsEachChangeUnderItsScreenAndNothingElse() throws {
        let fixture = try makeFixture(margins: ["m1", "m2"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try shown(fixture, "m1")

        fixture.model.setStarredForSharing(first, starred: true, place: .now)
        fixture.model.setStarredForSharing(first, starred: true, place: .now) // already on: no change, no count
        fixture.model.setStarredForSharing(try shown(fixture, "m2"), starred: true, place: .playerMargins)
        fixture.model.toggleStarredForSharing(first, place: .detail) // off
        fixture.model.setStarredForSharing(first, starred: true, place: .marginsTab)

        XCTAssertEqual(fixture.model.shareStarTally.load(), ShareStarTally(starsNow: 1, starsPlayerMargins: 1, starsElsewhere: 1, unstars: 1))
    }

    func testAFailedWriteAddsNothingToTheTally() throws {
        let fixture = try makeFixture(margins: ["m1"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let missing = margin(id: "gone", itemId: fixture.itemId, sessionId: fixture.sessionId)

        fixture.model.toggleStarredForSharing(missing, place: .now)

        XCTAssertEqual(fixture.model.shareStarTally.load(), ShareStarTally())
    }

    func testTheSheetRemembersHowItStarted() throws {
        let fixture = try makeFixture(margins: ["m1", "m2"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.model.prepareShareInterjections()
        XCTAssertEqual(fixture.model.sharingState.openedFrom, .all, "nothing starred")

        fixture.model.setStarredForSharing(try shown(fixture, "m1"), starred: true, place: .now)
        fixture.model.prepareShareInterjections()
        XCTAssertEqual(fixture.model.sharingState.openedFrom, .starred)

        fixture.model.presentReplyBackShare(ReplyBackOffer(replies: [try shown(fixture, "m2")], others: [], friendLabels: ["Cole"]))
        XCTAssertEqual(fixture.model.sharingState.openedFrom, .replies, "a reply sheet never starts from stars")

        fixture.model.openMarginShare(try shown(fixture, "m1"))
        XCTAssertEqual(fixture.model.sharingState.openedFrom, .single)
    }

    func testASendTapWritesOneLineWithCountsAndNoMarginWords() throws {
        let fixture = try makeFixture(margins: ["m1", "m2"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.setStarredForSharing(try shown(fixture, "m1"), starred: true, place: .now)
        fixture.model.prepareShareInterjections()
        let opened = fixture.model.sharingState.openedAt

        fixture.model.recordShareSelection(now: opened.addingTimeInterval(12))

        let lines = fixture.model.playbackEventRecording.events.filter { $0.kind == "share.selection" }
        XCTAssertEqual(lines.count, 1)
        let fields = try XCTUnwrap(lines.first?.fields)
        XCTAssertEqual(fields["opened"], "starred")
        XCTAssertEqual(fields["included"], "1")
        XCTAssertEqual(fields["starredIncluded"], "1")
        XCTAssertEqual(fields["starredLeftOut"], "0")
        XCTAssertEqual(fields["unstarredIncluded"], "0")
        XCTAssertEqual(fields["secondsInSheet"], "12")
        XCTAssertEqual(fields["starsNow"], "1")
        let everything = fields.keys.joined() + fields.values.joined()
        XCTAssertFalse(everything.contains("m1"), "no Margin id")
        XCTAssertFalse(everything.contains("Diagnostics"), "no Margin words")
    }

    func testThePresentedShareSheetStartsTheCountsAgain() throws {
        let fixture = try makeFixture(margins: ["m1"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.setStarredForSharing(try shown(fixture, "m1"), starred: true, place: .now)
        XCTAssertFalse(fixture.model.shareStarTally.load().isEmpty)

        fixture.model.shareSheetPresented()

        XCTAssertTrue(fixture.model.shareStarTally.load().isEmpty)
    }

    /// A retry after cancelling the system share sheet logs the counts the first send had, not zeros.
    func testARetryAfterTheCountsWereResetLogsTheSameCounts() throws {
        let fixture = try makeFixture(margins: ["m1", "m2"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.setStarredForSharing(try shown(fixture, "m1"), starred: true, place: .now)
        fixture.model.prepareShareInterjections()

        fixture.model.recordShareSelection()
        fixture.model.shareSheetPresented()
        fixture.model.recordShareSelection()

        let lines = fixture.model.playbackEventRecording.events.filter { $0.kind == "share.selection" }
        XCTAssertEqual(lines.compactMap { $0.fields["starsNow"] }, ["1", "1"])
        fixture.model.prepareShareInterjections() // a new sheet starts clean
        fixture.model.recordShareSelection()
        XCTAssertEqual(fixture.model.playbackEventRecording.events.filter { $0.kind == "share.selection" }.last?.fields["starsNow"], "0")
    }
}
