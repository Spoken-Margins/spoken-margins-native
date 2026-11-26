import Foundation
import XCTest
@testable import SessionKit

/// #4180 PR 1: the lookup that finds a live-session photo for the Library Margin it was saved as, through the item's
/// `LiveSessionRecord.savedMarginIds`. Load tests use real temporary folders and `LiveSessionRecord.save(in:)`.
final class SavedMarginPhotosTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "saved-margin-photos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    private func photo(session: String = "live", margin: String) -> LiveSessionPhoto {
        LiveSessionPhoto(path: "SpokenMargins/live-photos/\(session)/\(margin).jpg", widthPx: 100, heightPx: 100, byteCount: 1_000)!
    }

    private func margin(
        _ id: String, text: String = "words", withPhoto: Bool, session: String = "live", whereNote: String? = nil,
        place: LiveSessionPlace? = nil
    ) -> LiveSessionMargin {
        var margin = LiveSessionMargin(id: id, text: text, markedAt: start.addingTimeInterval(5), whereNote: whereNote)
        margin.place = place
        if withPhoto { margin.photo = photo(session: session, margin: id) }
        return margin
    }

    private func record(itemId: String, session: String = "live", margins: [LiveSessionMargin], links: [String: String]?) -> LiveSessionRecord {
        var live = LiveSession(id: session, kind: .paper, title: "Book", startedAt: start, savedItemId: itemId)
        live.margins = margins
        return LiveSessionRecord(itemId: itemId, session: live, transcript: nil, placed: [], savedMarginIds: links)
    }

    private func interjection(displayText: String?, cleaned: String?, transcript: String?) -> Interjection {
        Interjection(
            id: "saved-1", itemId: "item-1", sessionId: "s", targetType: .item, targetId: "item-1",
            createdAt: start, roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: transcript,
            cleanedTranscript: cleaned, displayText: displayText, status: "active"
        )
    }

    // MARK: The lookup

    func testARecordNamingAPhotoReturnsItForThatSavedMarginOnly() {
        let photos = SavedMarginPhotos(records: [record(
            itemId: "item-1",
            margins: [margin("live-a", withPhoto: true), margin("live-b", withPhoto: false)],
            links: ["live-a": "saved-a", "live-b": "saved-b"]
        )])

        XCTAssertEqual(photos.photo(forMarginId: "saved-a")?.photo, photo(margin: "live-a"))
        XCTAssertNil(photos.photo(forMarginId: "saved-b"), "the Margin without a photo has none")
        XCTAssertNil(photos.photo(forMarginId: "live-a"), "the live id is not a saved Margin's id")
    }

    func testARecordWithoutLinksAddsNothing() {
        let photos = SavedMarginPhotos(records: [record(itemId: "item-1", margins: [margin("live-a", withPhoto: true)], links: nil)])
        XCTAssertNil(photos.photo(forMarginId: "live-a"))
        XCTAssertTrue(photos.byMarginId.isEmpty)
        XCTAssertTrue(photos.marginIdsByItem.isEmpty)
    }

    func testARecordWhoseMarginsHaveNoPhotoAddsNothing() {
        let photos = SavedMarginPhotos(records: [record(
            itemId: "item-1", margins: [margin("live-a", withPhoto: false)], links: ["live-a": "saved-a"])])
        XCTAssertNil(photos.photo(forMarginId: "saved-a"))
        XCTAssertTrue(photos.marginIdsByItem.isEmpty)
    }

    func testAPhotoThatBreaksTheRulesIsLeftOut() throws {
        try record(itemId: "item-1", margins: [margin("live-a", withPhoto: true)], links: ["live-a": "saved-a"]).save(in: directory)
        XCTAssertNotNil(SavedMarginPhotos.load(from: directory).photo(forMarginId: "saved-a"), "the untampered file has the photo")

        // `path` is private(set), so the file is the only way in. JSONEncoder escapes slashes, so edit the JSON as a
        // tree rather than as a string.
        let url = LiveSessionRecord.url(itemId: "item-1", in: directory)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var session = try XCTUnwrap(json["session"] as? [String: Any])
        var margins = try XCTUnwrap(session["margins"] as? [[String: Any]])
        var photo = try XCTUnwrap(margins[0]["photo"] as? [String: Any])
        photo["path"] = "../outside.jpg"
        margins[0]["photo"] = photo
        session["margins"] = margins
        json["session"] = session
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let reread = try XCTUnwrap(LiveSessionRecord.load(itemId: "item-1", from: directory))
        XCTAssertEqual(reread.session.margins.first?.photo?.path, "../outside.jpg", "the file really holds the bad path")
        XCTAssertNil(SavedMarginPhotos.load(from: directory).photo(forMarginId: "saved-a"))
    }

    func testAnIdNotInTheLinksHasNoPhoto() {
        let photos = SavedMarginPhotos(records: [record(
            itemId: "item-1",
            margins: [margin("live-a", withPhoto: true), margin("live-b", withPhoto: true)],
            links: ["live-a": "saved-a"]
        )])
        XCTAssertNotNil(photos.photo(forMarginId: "saved-a"))
        XCTAssertNil(photos.photo(forMarginId: "friend-margin"), "a friend's Margin on the item is never in the links")
        XCTAssertEqual(photos.marginIdsByItem["item-1"], ["saved-a"], "a live Margin with no saved id is left out")
    }

    func testTwoLiveMarginsLinkedToOneSavedIdKeepTheFirst() {
        let photos = SavedMarginPhotos(records: [record(
            itemId: "item-1",
            margins: [margin("live-a", withPhoto: true), margin("live-b", withPhoto: true)],
            links: ["live-a": "saved-x", "live-b": "saved-x"]
        )])
        XCTAssertEqual(photos.photo(forMarginId: "saved-x")?.photo, photo(margin: "live-a"))
        XCTAssertEqual(photos.marginIdsByItem["item-1"], ["saved-x"])
    }

    func testRemovingAnItemDropsOnlyItsPhotos() {
        var photos = SavedMarginPhotos(records: [
            record(itemId: "item-1", session: "s1", margins: [margin("a", withPhoto: true, session: "s1")], links: ["a": "saved-1"]),
            record(itemId: "item-2", session: "s2", margins: [margin("b", withPhoto: true, session: "s2")], links: ["b": "saved-2"]),
        ])

        photos.remove(itemId: "item-1")

        XCTAssertNil(photos.photo(forMarginId: "saved-1"))
        XCTAssertNotNil(photos.photo(forMarginId: "saved-2"))
        XCTAssertNil(photos.marginIdsByItem["item-1"])
        photos.remove(itemId: "no-such-item") // harmless
        XCTAssertNotNil(photos.photo(forMarginId: "saved-2"))
    }

    func testASavedIdTwoItemsNameStaysWithTheFirstAndSurvivesTheOthersRemoval() {
        // Saved Margin ids are unique rows, so this is damaged data; removing one item must never strip the other.
        var photos = SavedMarginPhotos(records: [
            record(itemId: "item-1", session: "s1", margins: [margin("a", withPhoto: true, session: "s1")], links: ["a": "saved-x"]),
            record(itemId: "item-2", session: "s2", margins: [margin("b", withPhoto: true, session: "s2")], links: ["b": "saved-x"]),
        ])
        XCTAssertEqual(photos.photo(forMarginId: "saved-x")?.photo, photo(session: "s1", margin: "a"))
        XCTAssertNil(photos.marginIdsByItem["item-2"])

        photos.remove(itemId: "item-2")

        XCTAssertEqual(photos.photo(forMarginId: "saved-x")?.photo, photo(session: "s1", margin: "a"))
    }

    func testAMergeGivesACollidingIdToTheTouchedItem() {
        let loaded = SavedMarginPhotos(records: [
            record(itemId: "item-1", session: "s1", margins: [margin("a", withPhoto: true, session: "s1")], links: ["a": "saved-x"]),
        ])
        var current = SavedMarginPhotos(records: [])
        current.add(record(itemId: "item-2", session: "s2", margins: [margin("b", withPhoto: true, session: "s2")], links: ["b": "saved-x"]))

        let merged = current.merging(loaded: loaded, touchedItemIds: ["item-2"])

        XCTAssertEqual(merged.photo(forMarginId: "saved-x")?.photo, photo(session: "s2", margin: "b"))
    }

    func testAddingARecordAgainReplacesItsEntries() {
        var photos = SavedMarginPhotos(records: [record(
            itemId: "item-1", margins: [margin("a", withPhoto: true), margin("b", withPhoto: true)],
            links: ["a": "saved-a", "b": "saved-b"])])

        photos.add(record(itemId: "item-1", margins: [margin("b", withPhoto: true)], links: ["b": "saved-b"]))

        XCTAssertNil(photos.photo(forMarginId: "saved-a"), "the old entry does not linger")
        XCTAssertNotNil(photos.photo(forMarginId: "saved-b"))
        XCTAssertEqual(photos.marginIdsByItem["item-1"], ["saved-b"])
    }

    func testAnAddOrRemoveDuringALoadSurvivesIt() {
        // The launch load read item-1 and item-2 from disk.
        let loaded = SavedMarginPhotos(records: [
            record(itemId: "item-1", session: "s1", margins: [margin("a", withPhoto: true, session: "s1")], links: ["a": "saved-1"]),
            record(itemId: "item-2", session: "s2", margins: [margin("b", withPhoto: true, session: "s2")], links: ["b": "saved-2"]),
        ])
        // Meanwhile on the main actor: item-3 was saved, item-2 was purged (it was never in the in-memory value yet).
        var current = SavedMarginPhotos(records: [])
        current.add(record(itemId: "item-3", session: "s3", margins: [margin("c", withPhoto: true, session: "s3")], links: ["c": "saved-3"]))
        current.remove(itemId: "item-2")

        let merged = current.merging(loaded: loaded, touchedItemIds: ["item-3", "item-2"])

        XCTAssertNotNil(merged.photo(forMarginId: "saved-1"), "an untouched item comes from the load")
        XCTAssertNil(merged.photo(forMarginId: "saved-2"), "an item purged after the load began does not come back")
        XCTAssertNotNil(merged.photo(forMarginId: "saved-3"), "an item saved after the load began is kept")
        XCTAssertEqual(Set(merged.marginIdsByItem.keys), ["item-1", "item-3"])
    }

    func testAnItemSavedAgainDuringALoadKeepsItsNewEntries() {
        let loaded = SavedMarginPhotos(records: [record(
            itemId: "item-1", margins: [margin("a", withPhoto: true), margin("b", withPhoto: true)],
            links: ["a": "saved-a", "b": "saved-b"])])
        var current = SavedMarginPhotos(records: [])
        current.add(record(itemId: "item-1", margins: [margin("b", withPhoto: true)], links: ["b": "saved-b"]))

        let merged = current.merging(loaded: loaded, touchedItemIds: ["item-1"])

        XCTAssertNil(merged.photo(forMarginId: "saved-a"), "the stale loaded entry loses to the newer save")
        XCTAssertNotNil(merged.photo(forMarginId: "saved-b"))
    }

    // MARK: Loading from disk

    func testLoadReadsRecordsFromTheirFolder() throws {
        try record(itemId: "item-1", session: "s1", margins: [margin("a", withPhoto: true, session: "s1")], links: ["a": "saved-1"])
            .save(in: directory)
        try record(itemId: "item-2", session: "s2", margins: [margin("b", withPhoto: false, session: "s2")], links: ["b": "saved-2"])
            .save(in: directory)

        let photos = SavedMarginPhotos.load(from: directory)

        XCTAssertEqual(photos.photo(forMarginId: "saved-1")?.photo, photo(session: "s1", margin: "a"))
        XCTAssertNil(photos.photo(forMarginId: "saved-2"))
        XCTAssertEqual(Array(photos.marginIdsByItem.keys), ["item-1"])
    }

    func testAMissingFolderLoadsEmpty() {
        let photos = SavedMarginPhotos.load(from: directory.appending(path: "nowhere"))
        XCTAssertEqual(photos, SavedMarginPhotos(records: []))
    }

    // MARK: Text alternative

    func testTheAltTextFollowsTheMarginsCurrentWords() throws {
        let page = try XCTUnwrap(LiveSessionPlace(unit: .page, value: 118))
        let rows: [(SavedMarginPhoto, String, String)] = [
            (SavedMarginPhoto(photo: photo(margin: "a"), whereNote: "ch 5", place: page), "Tidied words", "Photo with Margin: Tidied words"),
            (SavedMarginPhoto(photo: photo(margin: "a"), whereNote: "ch 5", place: page), "", "Photo of the page at page 118"),
            (SavedMarginPhoto(photo: photo(margin: "a"), whereNote: "ch 5", place: nil), " ", "Photo of the page at ch 5"),
            (SavedMarginPhoto(photo: photo(margin: "a"), whereNote: nil, place: nil), "", "Photo of the page"),
        ]
        for (index, (entry, words, expected)) in rows.enumerated() {
            XCTAssertEqual(entry.altText(currentText: words), expected, "row \(index)")
        }
    }

    func testTheAltTextForAnInterjectionUsesItsOwnWords() throws {
        let page = try XCTUnwrap(LiveSessionPlace(unit: .page, value: 12))
        let entry = SavedMarginPhoto(photo: photo(margin: "a"), whereNote: nil, place: page)

        XCTAssertEqual(
            entry.altText(for: interjection(displayText: nil, cleaned: nil, transcript: "spoken words")),
            "Photo with Margin: spoken words")
        XCTAssertEqual(
            entry.altText(for: interjection(displayText: "shown words", cleaned: nil, transcript: "spoken words")),
            "Photo with Margin: shown words")
        XCTAssertEqual(
            entry.altText(for: interjection(displayText: "  ", cleaned: nil, transcript: "spoken words")),
            "Photo with Margin: spoken words", "blank shown words fall through to the transcript")
        XCTAssertEqual(
            entry.altText(for: interjection(displayText: " ", cleaned: "", transcript: nil)),
            "Photo of the page at page 12", "a spoken Margin still transcribing falls back to the place")
    }
}
