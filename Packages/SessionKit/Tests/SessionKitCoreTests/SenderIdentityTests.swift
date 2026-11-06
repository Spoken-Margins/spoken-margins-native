import Foundation
@testable import SessionKit
import XCTest

/// The device-only pieces of hiding a sender (#2846): the random sender id, the per-group ledger, the hidden list and
/// the file that keeps them. The packet side is in SenderIdentityPacketTests.
final class SenderIdentityTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private let senderA = "0123456789abcdef0123456789abcdef"
    private let senderB = "fedcba9876543210fedcba9876543210"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SenderIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func layer(_ id: String, sender: String?) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, packageDigest: String(repeating: "a", count: 64), packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/\(id)", title: id),
            displayLabel: "A Friend", importedAt: created, senderId: sender
        )
    }

    func testThePhoneKeepsOneRandomIdAcrossSharesAndRelaunches() throws {
        let store = SenderIdentityFileStore<SenderIDLedger>.ledger(in: root)
        let first = try XCTUnwrap(store.phoneSenderID())
        XCTAssertTrue(SenderID.isValid(first))
        XCTAssertEqual(store.phoneSenderID(), first, "a second share carries the same id, so one hide covers both")
        XCTAssertEqual(SenderIdentityFileStore<SenderIDLedger>.ledger(in: root).phoneSenderID(), first, "and after a relaunch")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("SenderIdentityTests-other-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }
        XCTAssertNotEqual(try XCTUnwrap(SenderIdentityFileStore<SenderIDLedger>.ledger(in: other).phoneSenderID()), first, "another phone's id is its own")
    }

    func testADamagedLedgerIsReplacedByAValidKeptId() throws {
        try Data("not json".utf8).write(to: root.appendingPathComponent("sender-ids.json"))
        let store = SenderIdentityFileStore<SenderIDLedger>.ledger(in: root)
        let id = try XCTUnwrap(store.phoneSenderID(), "a damaged file is replaced, not a reason to share without an id")
        XCTAssertTrue(SenderID.isValid(id))
        XCTAssertEqual(store.phoneSenderID(), id, "and the next share keeps the id that replaced it")
    }

    func testAnIdThatCannotBeKeptIsNotSharedAndAGoodFileIsNeverOverwrittenByAFailedRead() throws {
        // The folder cannot be made (its parent is a file): no id that would change on every share goes out.
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        XCTAssertNil(SenderIdentityFileStore<SenderIDLedger>.ledger(in: blocker.appendingPathComponent("Senders")).phoneSenderID())

        // The file is there but cannot be read (here, a directory stands in for a locked file): it is left alone.
        let unreadable = root.appendingPathComponent("unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable.appendingPathComponent("sender-ids.json"), withIntermediateDirectories: true)
        XCTAssertNil(SenderIdentityFileStore<SenderIDLedger>.ledger(in: unreadable).phoneSenderID())
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.appendingPathComponent("sender-ids.json").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "nothing was written over it")
    }

    func testHiddenSendersHideTheirLayersAndNoOnesElse() {
        let layers = [layer("a1", sender: senderA), layer("b1", sender: senderB), layer("none", sender: nil), layer("a2", sender: senderA)]
        var hidden = HiddenSenders()
        XCTAssertEqual(hidden.visible(layers).map(\.id), ["a1", "b1", "none", "a2"])
        hidden.hide(senderA, displayLabel: "A Friend", at: created)
        XCTAssertEqual(hidden.visible(layers).map(\.id), ["b1", "none"], "every layer of the sender, and a layer with no sender id stays")
        hidden.unhide(senderA)
        XCTAssertEqual(hidden.visible(layers).map(\.id), ["a1", "b1", "none", "a2"], "undo brings everything back")
    }

    func testOnlyARealSenderIdCanBeHidden() {
        var hidden = HiddenSenders()
        for bad in [nil, "", "short", "has spaces in it, has spaces", String(repeating: "a", count: 65)] as [String?] {
            XCTAssertFalse(hidden.hide(bad))
        }
        XCTAssertTrue(hidden.entries.isEmpty)
        XCTAssertEqual(HiddenSenders(entries: [.init(senderId: "bad", displayLabel: nil, hiddenAt: created)]).entries, [],
                       "a damaged saved entry is dropped, not kept")
    }

    func testHidingTwiceKeepsOneEntryAndTheFirstLabel() {
        var hidden = HiddenSenders()
        hidden.hide(senderA, displayLabel: "First", at: created)
        hidden.hide(senderA, displayLabel: "Second", at: created.addingTimeInterval(60))
        XCTAssertEqual(hidden.entries.map(\.displayLabel), ["First"])
    }

    func testTheHiddenListIsKeptOnDeviceAndSurvivesARestart() throws {
        let store = SenderIdentityFileStore<HiddenSenders>.hiddenSenders(in: root.appendingPathComponent("state"))
        XCTAssertEqual(store.load(), HiddenSenders(), "nothing hidden before the first save")
        var hidden = store.load()
        hidden.hide(senderB, displayLabel: "B", at: created)
        try store.save(hidden)
        XCTAssertEqual(SenderIdentityFileStore<HiddenSenders>.hiddenSenders(in: root.appendingPathComponent("state")).load(), hidden)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), HiddenSenders(), "a damaged file reads as nothing hidden, not a crash")
    }

    func testTheLedgerGivesOneIdPerGroupAndNeverReusesOne() {
        var ledger = SenderIDLedger()
        let family = ledger.senderID(forGroup: "family")
        let club = ledger.senderID(forGroup: "club")
        XCTAssertTrue(SenderID.isValid(family))
        XCTAssertNotEqual(family, club, "nothing links a sender across groups")
        XCTAssertEqual(ledger.senderID(forGroup: "family"), family, "the same group keeps its id")
        // A maker that repeats itself or returns junk can't link two groups or write an id readers refuse.
        let stuck = ledger.senderID(forGroup: "book", makeID: { family })
        XCTAssertNotEqual(stuck, family)
        XCTAssertTrue(SenderID.isValid(ledger.senderID(forGroup: "junk", makeID: { "x" })))
        XCTAssertEqual(Set(ledger.idsByGroup.values).count, ledger.idsByGroup.count)
    }

    func testGeneratedIdsAreRandomHex() {
        let ids = (0..<50).map { _ in SenderID.generate() }
        XCTAssertEqual(Set(ids).count, 50)
        for id in ids {
            XCTAssertEqual(id.count, 32)
            XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
        }
        var seeded = SystemRandomNumberGenerator()
        XCTAssertTrue(SenderID.isValid(SenderID.generate(using: &seeded)))
    }

    // #2846: hiding one received Margin on its own.
    func testASingleMarginCanBeHiddenAndShownAgainWithoutTouchingTheSenders() {
        var hidden = HiddenSenders()
        XCTAssertTrue(hidden.isEmpty)
        hidden.hide(senderA, displayLabel: "A", at: created)
        XCTAssertTrue(hidden.hideMargin("margin-1", senderLabel: "A", text: "  First   words\nhere ", at: created))
        XCTAssertFalse(hidden.hideMargin("", text: "no id"), "a Margin with no id can't be named, so it isn't hidden")
        XCTAssertTrue(hidden.isMarginHidden("margin-1"))
        XCTAssertFalse(hidden.isMarginHidden("margin-2"))
        XCTAssertEqual(hidden.listedMargins.map(\.snippet), ["First words here"], "whitespace is collapsed in the kept words")
        hidden.unhideMargin("margin-1")
        XCTAssertFalse(hidden.isMarginHidden("margin-1"))
        XCTAssertEqual(hidden.entries.count, 1, "showing a Margin again leaves the hidden sender hidden")
        hidden.unhide(senderA)
        XCTAssertTrue(hidden.isEmpty)
    }

    func testHidingAMarginTwiceKeepsOneEntryAndTheKeptWordsAreShort() {
        var hidden = HiddenSenders()
        hidden.hideMargin("m", text: String(repeating: "word ", count: 100), at: created)
        hidden.hideMargin("m", text: "other", at: created.addingTimeInterval(60))
        XCTAssertEqual(hidden.margins.count, 1)
        XCTAssertLessThanOrEqual(hidden.margins[0].snippet.count, HiddenSenders.HiddenMargin.snippetLimit + 1)
        XCTAssertTrue(hidden.margins[0].snippet.hasSuffix("…"))
    }

    func testHiddenMarginsAreFilteredOutOfAMarginList() {
        func margin(_ id: String) -> ImportedCommentaryInterjection {
            ImportedCommentaryInterjection(
                id: id, layerId: "layer", packageScopedId: id, createdAt: created,
                anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000),
                approvedTranscript: id, resolution: ImportedAnchorResolution(evidenceClass: .exactEdition))
        }
        var hidden = HiddenSenders()
        XCTAssertEqual(hidden.visible([margin("a"), margin("b")]).map(\.id), ["a", "b"])
        hidden.hideMargin("a")
        XCTAssertEqual(hidden.visible([margin("a"), margin("b")]).map(\.id), ["b"])
    }

    func testTheHiddenMarginsSurviveARestartAndAFileFromBeforeThemStillReads() throws {
        let store = SenderIdentityFileStore<HiddenSenders>.hiddenSenders(in: root.appendingPathComponent("margins-state"))
        var hidden = HiddenSenders()
        hidden.hide(senderA, displayLabel: "A", at: created)
        hidden.hideMargin("margin-1", senderLabel: "A", text: "words", at: created)
        try store.save(hidden)
        XCTAssertEqual(store.load(), hidden)
        // A file written by the build that only knew senders has no "margins" key.
        try Data(#"{"entries":[{"senderId":"0123456789abcdef0123456789abcdef","hiddenAt":"2026-11-05T00:00:00Z"}]}"#.utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load().entries.map(\.senderId), [senderA])
        XCTAssertEqual(store.load().margins, [])
    }

    func testASavedFileGoesThroughTheSameChecksAsANewValue() throws {
        let ledgerJSON = #"{"idsByGroup":{"a":"0123456789abcdef0123456789abcdef","b":"0123456789abcdef0123456789abcdef","c":"bad"}}"#
        let ledger = try JSONDecoder().decode(SenderIDLedger.self, from: Data(ledgerJSON.utf8))
        XCTAssertEqual(ledger.idsByGroup, ["a": senderA], "a repeated id and a bad one are dropped, so no two groups share an id")
        let hiddenJSON = #"{"entries":[{"senderId":"0123456789abcdef0123456789abcdef","hiddenAt":"2026-11-05T00:00:00Z"},{"senderId":"0123456789abcdef0123456789abcdef","hiddenAt":"2026-11-05T00:00:00Z"},{"senderId":"x","hiddenAt":"2026-11-05T00:00:00Z"}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(HiddenSenders.self, from: Data(hiddenJSON.utf8)).entries.map(\.senderId), [senderA])
    }

    func testAMakerThatKeepsReturningTheSameIdStillGetsAFreshOne() {
        var ledger = SenderIDLedger()
        let first = ledger.senderID(forGroup: "one", makeID: { "0123456789abcdef0123456789abcdef" })
        let second = ledger.senderID(forGroup: "two", makeID: { "0123456789abcdef0123456789abcdef" })
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(SenderID.isValid(first) && SenderID.isValid(second))
    }
}
