import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #3794: the Library row names who sent the Margins, "Completed hidden" says when it hides friends' Margins, and the
/// search finds an item through the sender's name. Table tests over the Design's rows and its name table.
final class SharedMarginTallyWordsTests: XCTestCase {
    private typealias Sender = SharedMarginTally.Sender

    private func tally(_ total: Int, new: Int, replies: Int = 0, _ senders: [(String?, Int)]) -> SharedMarginTally {
        SharedMarginTally(total: total, new: new,
                          senders: senders.enumerated().map { Sender(key: "s\($0.offset)", name: $0.element.0, count: $0.element.1) },
                          replies: replies)
    }

    // MARK: The row line

    func testTheLineFollowsOneRuleForEveryCase() {
        struct Row { let name: String; let tally: SharedMarginTally; let line: String; let spoken: String }
        let rows = [
            Row(name: "all new", tally: tally(2, new: 2, [("Cole", 2)]),
                line: "2 new Margins from Cole", spoken: "2 new Margins from Cole"),
            Row(name: "one, new", tally: tally(1, new: 1, [("Cole", 1)]),
                line: "1 new Margin from Cole", spoken: "1 new Margin from Cole"),
            Row(name: "some heard", tally: tally(3, new: 1, [("Cole", 3)]),
                line: "3 Margins from Cole · 1 new", spoken: "3 Margins from Cole, 1 new to you"),
            Row(name: "all heard", tally: tally(2, new: 0, [("Cole", 2)]),
                line: "2 Margins from Cole", spoken: "2 Margins from Cole"),
            Row(name: "replies, all new", tally: tally(2, new: 2, replies: 2, [("Sam", 2)]),
                line: "2 new replies from Sam", spoken: "2 new replies from Sam"),
            Row(name: "replies, some new", tally: tally(3, new: 1, replies: 3, [("Sam", 3)]),
                line: "3 replies from Sam · 1 new", spoken: "3 replies from Sam, 1 new to you"),
            Row(name: "replies, none new", tally: tally(2, new: 0, replies: 2, [("Sam", 2)]),
                line: "2 replies from Sam", spoken: "2 replies from Sam"),
            Row(name: "a reply and a Margin, all new", tally: tally(2, new: 2, replies: 1, [("Sam", 2)]),
                line: "1 new reply and 1 new Margin from Sam", spoken: "1 new reply and 1 new Margin from Sam"),
            Row(name: "a reply and a Margin, some new", tally: tally(2, new: 1, replies: 1, [("Sam", 2)]),
                line: "1 reply and 1 Margin from Sam · 1 new", spoken: "1 reply and 1 Margin from Sam, 1 new to you"),
            Row(name: "a reply and a Margin, none new", tally: tally(2, new: 0, replies: 1, [("Sam", 2)]),
                line: "1 reply and 1 Margin from Sam", spoken: "1 reply and 1 Margin from Sam"),
            Row(name: "two senders count replies as Margins", tally: tally(5, new: 5, replies: 2, [("Cole", 3), ("Sam", 2)]),
                line: "5 new Margins from Cole and Sam", spoken: "5 new Margins from Cole and Sam"),
            Row(name: "two senders, some new", tally: tally(5, new: 2, [("Cole", 3), ("Sam", 2)]),
                line: "5 Margins from Cole and Sam · 2 new", spoken: "5 Margins from Cole and Sam, 2 new to you"),
            Row(name: "three senders", tally: tally(5, new: 2, [("Cole", 2), ("Sam", 2), ("Ana", 1)]),
                line: "5 Margins from 3 friends · 2 new", spoken: "5 Margins from 3 friends, 2 new to you"),
            Row(name: "three senders, all new", tally: tally(5, new: 5, [("Cole", 2), ("Sam", 2), ("Ana", 1)]),
                line: "5 new Margins from 3 friends", spoken: "5 new Margins from 3 friends"),
            Row(name: "no name", tally: tally(2, new: 2, [(nil, 2)]),
                line: "2 new Margins from a friend", spoken: "2 new Margins from a friend"),
            Row(name: "the app's stand-ins are no name", tally: tally(2, new: 2, [("Someone", 1), ("A Friend", 1)]),
                line: "2 new Margins from friends", spoken: "2 new Margins from friends"),
            Row(name: "one named, one not", tally: tally(3, new: 3, [("Cole", 2), (nil, 1)]),
                line: "3 new Margins from Cole and a friend", spoken: "3 new Margins from Cole and a friend"),
            Row(name: "no senders read", tally: SharedMarginTally(total: 2, new: 2),
                line: "2 new Margins from a friend", spoken: "2 new Margins from a friend")
        ]
        for row in rows {
            XCTAssertEqual(row.tally.senderLine, row.line, row.name)
            XCTAssertEqual(row.tally.senderAccessibilityLine, row.spoken, row.name)
        }
        XCTAssertNil(SharedMarginTally.none.senderLine)
        XCTAssertNil(SharedMarginTally.none.senderAccessibilityLine)
    }

    func testTheSenderOrderIsMostMarginsFirstThenByName() {
        XCTAssertEqual(tally(4, new: 0, [("Sam", 1), ("Cole", 3)]).senderLine, "4 Margins from Cole and Sam")
        XCTAssertEqual(tally(4, new: 0, [("Sam", 2), ("ana", 2)]).senderLine, "4 Margins from ana and Sam", "ties by name, ignoring case")
        XCTAssertEqual(tally(4, new: 0, [(nil, 3), ("Cole", 1)]).senderLine, "4 Margins from a friend and Cole")
    }

    func testNamesAreCheckedAgainstTheNameTable() {
        func line(_ name: String?) -> String { tally(1, new: 1, [(name, 1)]).senderLine ?? "" }
        XCTAssertEqual(line("O'Brien"), "1 new Margin from O'Brien", "an apostrophe")
        XCTAssertEqual(line("Zoë 🎧"), "1 new Margin from Zoë 🎧", "an accent and an emoji")
        XCTAssertEqual(line("  Cole  "), "1 new Margin from Cole", "whitespace trimmed")
        XCTAssertEqual(line(""), "1 new Margin from a friend", "empty")
        XCTAssertEqual(line("   "), "1 new Margin from a friend", "blank")
        let long = String(repeating: "a", count: 40)
        XCTAssertEqual(line(long), "1 new Margin from " + String(repeating: "a", count: 23) + "…", "over 24 characters")
        XCTAssertEqual(line(String(repeating: "a", count: 24)), "1 new Margin from " + String(repeating: "a", count: 24), "exactly 24 stays")
        XCTAssertTrue(tally(3, new: 1, [(long, 3)]).senderLine?.hasSuffix(" · 1 new") ?? false, "the count and new stay readable")
    }

    func testTheSameFriendInTwoPacketsIsCountedOnce() {
        let merged = SharedMarginTally(total: 3, new: 3, senders: [
            Sender(key: "abc", name: "Cole", count: 2), Sender(key: "abc", name: nil, count: 1)
        ])
        XCTAssertEqual(merged.senders.count, 1)
        XCTAssertEqual(merged.senderLine, "3 new Margins from Cole", "the name from the packet that had one")
        let byName = SharedMarginTally(total: 3, new: 3, senders: [
            Sender(name: "Cole", count: 2), Sender(name: "COLE", count: 1)
        ])
        XCTAssertEqual(byName.senders.count, 1, "no id: the same name is the same friend")
        let twoIds = SharedMarginTally(total: 2, new: 2, senders: [
            Sender(key: "one", name: "Cole", count: 1), Sender(key: "two", name: "Cole", count: 1)
        ])
        XCTAssertEqual(twoIds.senders.count, 2, "two ids are two people, even with one name")
    }

    // MARK: Search

    func testSearchFindsAnItemThroughANamedSender() {
        let item = tally(3, new: 1, [("Zoë", 2), ("Cole", 1), (nil, 1)])
        XCTAssertTrue(item.senderMatches("cole"))
        XCTAssertTrue(item.senderMatches("COL"))
        XCTAssertTrue(item.senderMatches("zoe"), "diacritics ignored")
        XCTAssertTrue(item.senderMatches("  Cole "), "whitespace ignored")
        XCTAssertFalse(item.senderMatches("friend"), "an unnamed sender matches nothing")
        XCTAssertFalse(item.senderMatches("someone"))
        XCTAssertFalse(item.senderMatches(""))
        XCTAssertFalse(item.senderMatches("sam"))
        XCTAssertFalse(SharedMarginTally.none.senderMatches("cole"))
        XCTAssertFalse(SharedMarginTally(total: 1, new: 1).senderMatches("cole"), "no sender read")
    }

    // MARK: Completed hidden

    func testCompletedHiddenSaysWhatItHides() {
        let cole = tally(2, new: 0, [("Cole", 2)])
        let both = tally(3, new: 0, [("Cole", 2), ("Sam", 1)])
        let stranger = tally(1, new: 0, [(nil, 1)])
        XCTAssertNil(LibraryCompletedHiddenNote.words(items: []))
        XCTAssertNil(LibraryCompletedHiddenNote.words(items: [.none]))
        XCTAssertEqual(LibraryCompletedHiddenNote.words(items: [cole]), "1 has Margins from Cole")
        XCTAssertEqual(LibraryCompletedHiddenNote.words(items: [both]), "1 has Margins from friends")
        XCTAssertEqual(LibraryCompletedHiddenNote.words(items: [stranger]), "1 has Margins from a friend")
        XCTAssertEqual(LibraryCompletedHiddenNote.words(items: [cole, both]), "2 have Margins from friends")
        XCTAssertEqual(LibraryCompletedHiddenNote.words(items: [cole, .none]), "1 has Margins from Cole", "an item with none is not counted")
    }

    // MARK: The store

    private func layer(_ id: String, item: String, label: String?, sender: String?, deleted: Bool = false) -> ImportedCommentaryLayer {
        var layer = ImportedCommentaryLayer(
            id: id, itemId: item, packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: label, importedAt: Date(timeIntervalSince1970: 1_700_000_000), deletedAt: deleted ? Date(timeIntervalSince1970: 1_700_000_000) : nil
        )
        layer.senderId = sender
        return layer
    }

    private func margin(_ id: String, layer: String) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layer, packageScopedId: id, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Listen to this part.",
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000
        )
    }

    /// Real SQLite: the names come from the same read as the counts, merged per friend, with hidden senders and deleted
    /// layers left out exactly as they are left out of the count, and they survive a reopen.
    func testTheStoreNamesWhoSentTheMargins() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "tally-senders-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SQLiteSessionStore(path: path)
        for id in ["a", "b"] { try store.saveItem(Item(id: id, title: "Title \(id)", mediaType: "text", text: "Words.", externalReference: nil, status: "ready")) }
        let cole = "cccccccccccccccccccccccccccccccc", sam = "dddddddddddddddddddddddddddddddd"
        // a: Cole in two packets (two layers), Sam once, and a deleted layer of Ana's. b: a layer with no name and no id.
        _ = try store.importCommentaryLayer(layer("c1", item: "a", label: "Cole", sender: cole), interjections: [margin("m1", layer: "c1"), margin("m2", layer: "c1")])
        _ = try store.importCommentaryLayer(layer("c2", item: "a", label: "Cole M.", sender: cole), interjections: [margin("m3", layer: "c2")])
        _ = try store.importCommentaryLayer(layer("s1", item: "a", label: "Sam", sender: sam), interjections: [margin("m4", layer: "s1")])
        _ = try store.importCommentaryLayer(layer("gone", item: "a", label: "Ana", sender: nil, deleted: true), interjections: [margin("m5", layer: "gone")])
        _ = try store.importCommentaryLayer(layer("anon", item: "b", label: nil, sender: nil), interjections: [margin("m6", layer: "anon")])

        let tallies = try SQLiteSessionStore(path: path).loadSharedMarginTallies()
        XCTAssertEqual(tallies["a"]?.senderLine, "4 new Margins from Cole and Sam", "Cole once, though two packets; the deleted layer is not a sender")
        XCTAssertEqual(tallies["a"]?.senders.map(\.count), [3, 1])
        XCTAssertEqual(tallies["b"]?.senderLine, "1 new Margin from a friend")

        var hidden = HiddenSenders()
        hidden.hide(cole)
        let without = try store.loadSharedMarginTallies(hiding: hidden)
        XCTAssertEqual(without["a"]?.senderLine, "1 new Margin from Sam", "a hidden sender leaves the names as it leaves the count")
        XCTAssertEqual(without["a"]?.total, 1)
        XCTAssertTrue(try store.loadSharedMarginTallies()["a"]?.senderMatches("cole") ?? false)
        XCTAssertFalse(without["a"]?.senderMatches("cole") ?? true, "and the search")
    }
}
