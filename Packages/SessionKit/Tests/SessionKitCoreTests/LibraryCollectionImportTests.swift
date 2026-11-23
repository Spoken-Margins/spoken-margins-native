import Foundation
import XCTest
@testable import SessionKit

/// #3769: a picked folder or titled link list becomes a collection. What the pick starts, where each item lands as the
/// importers finish, and the one line said at the end.
final class LibraryCollectionImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let path = "/Users/x/Documents/Reading group"

    private func file(_ key: String, _ sha: String, kind: LibraryFolderWalk.Kind = .pdf) -> LibraryFolderWalk.Member {
        .init(key: key, kind: kind, size: 10, sha256: sha, url: URL(fileURLWithPath: "/tmp/\(key)"), address: nil, title: nil,
              isNotDownloaded: false)
    }

    private func walk(_ members: [LibraryFolderWalk.Member], notAdded: [LibraryFolderWalk.NotAdded] = []) -> LibraryFolderWalk.Result {
        .init(members: members, notAdded: notAdded, skippedOtherCount: 0, filesCapped: false, entriesCapped: false, hasDeeperFolders: false)
    }

    private var counter = 0
    private func nextID() -> String { counter += 1; return "item-\(counter)" }

    private func start(_ result: LibraryFolderWalk.Result, name: String = "Reading group", folders: [LibraryFolderRecord] = [],
                       collections: [ItemCollection] = []) -> LibraryCollectionImport.Start {
        LibraryCollectionImport.start(walk: result, pickedPath: path, bookmark: nil, name: name, folders: folders,
                                      collections: collections, now: now, collectionID: "collection-new", makeItemID: { self.nextID() })
    }

    // MARK: Starting

    func testANewPickMakesANamedCollectionWithEveryFileAsAJob() {
        let begun = start(walk([file("b.pdf", "1"), file("a.pdf", "2")]))
        XCTAssertTrue(begun.isNew)
        XCTAssertEqual(begun.collection.id, "collection-new")
        XCTAssertEqual(begun.record.id, "collection-new", "the record shares the collection's ID")
        XCTAssertEqual(begun.collection.name, "Reading group")
        XCTAssertEqual(begun.collection.itemIDs, [], "items join as they land, never before they exist")
        XCTAssertEqual(begun.jobs.map(\.itemID), ["item-1", "item-2"])
        XCTAssertTrue(LibraryCollectionImport.savesCollection(begun))
    }

    func testANameAlreadyTakenGetsANumberAndAnEmptyNameFallsBack() {
        let taken = [ItemCollection(id: "c", name: "reading group", createdAt: now)]
        XCTAssertEqual(start(walk([file("a.pdf", "1")]), collections: taken).collection.name, "Reading group 2")
        XCTAssertEqual(start(walk([file("a.pdf", "1")]), name: "   ").collection.name, "Imported")
    }

    func testPickingTheSamePlaceAgainAddsToItsCollection() {
        let first = start(walk([file("a.pdf", "1")]))
        var record = first.record
        var collection = first.collection
        LibraryCollectionImport.settle(first.jobs[0], outcome: .added(itemID: "item-1"), record: &record, collection: &collection, now: now)
        collection.name = "Renamed by the listener"
        let again = start(walk([file("a.pdf", "1"), file("b.pdf", "2")]), folders: [record], collections: [collection])
        XCTAssertFalse(again.isNew)
        XCTAssertEqual(again.collection, collection, "its name and items are the listener's")
        XCTAssertEqual(again.jobs.map(\.memberKey), ["b.pdf"])
    }

    func testARecordWhoseCollectionWasDeletedStartsAFreshCollection() {
        let orphan = LibraryFolderRecord(id: "collection-old", sourcePath: path, importedAt: now)
        let begun = start(walk([file("a.pdf", "1")]), folders: [orphan], collections: [])
        XCTAssertTrue(begun.isNew)
        XCTAssertEqual(begun.collection.id, "collection-new")
    }

    func testANewPickWithNothingToImportSavesNothing() {
        let begun = start(walk([], notAdded: [.init(key: "x.spokenmargins", name: "x.spokenmargins", reason: "packet")]))
        XCTAssertFalse(LibraryCollectionImport.savesCollection(begun))
    }

    func testOneLinkListReadsLikeAFolderHoldingIt() {
        let list = LinkListFile(title: "Week 3", entries: [.init(url: "https://a.example/1", title: "One"), .init(url: "https://a.example/2")],
                                skipped: [.init(position: 3, text: "ftp://x", reason: "not https")])
        let result = LibraryFolderWalk.linkList(list, named: "week.json")
        XCTAssertEqual(result.members.map(\.key), ["week.json#001", "week.json#002"])
        XCTAssertEqual(result.members.map(\.address), ["https://a.example/1", "https://a.example/2"])
        XCTAssertEqual(result.members.map(\.kind), [.link, .link])
        XCTAssertEqual(result.notAdded.map(\.key), ["week.json#003"])
        let begun = start(result, name: "Week 3")
        XCTAssertEqual(begun.jobs.map(\.itemID), [nil, nil], "a link's item is known once it is added")
    }

    func testAFollowEntryIsNeverAMemberOfAFolderOrListCollection() {
        // #4683: a show to follow is a suggestion, not an item, in every route that reads a list.
        let list = LinkListFile(title: "Brief", entries: [
            .init(url: "https://a.example/1"),
            .init(url: "https://feeds.example/show.xml", follow: true),
            .init(url: "https://a.example/2"),
        ])
        let result = LibraryFolderWalk.linkList(list, named: "brief.json")
        XCTAssertEqual(result.members.map(\.address), ["https://a.example/1", "https://a.example/2"])
        XCTAssertEqual(result.members.map(\.key), ["brief.json#001", "brief.json#002"])
        // A list of only follows has nothing to make a collection of.
        let onlyFollows = LinkListFile(title: "Shows", entries: [.init(url: "https://feeds.example/a.xml", follow: true)])
        XCTAssertTrue(LibraryFolderWalk.linkList(onlyFollows, named: "shows.json").members.isEmpty)
        XCTAssertFalse(LibraryCollectionImport.savesCollection(start(LibraryFolderWalk.linkList(onlyFollows, named: "shows.json"), name: "Shows")))
    }

    // MARK: Settling

    func testItemsLandInFolderOrderWhateverOrderTheImportersFinishIn() {
        let begun = start(walk([file("1.pdf", "a"), file("2.pdf", "b"), file("3.pdf", "c"), file("4.pdf", "d")]))
        var record = begun.record
        var collection = begun.collection
        for index in [2, 0, 3, 1] {
            let job = begun.jobs[index]
            LibraryCollectionImport.settle(job, outcome: .added(itemID: job.itemID!), record: &record, collection: &collection, now: now)
        }
        XCTAssertEqual(collection.itemIDs, ["item-1", "item-2", "item-3", "item-4"])
        XCTAssertTrue(record.members.allSatisfy { $0.state == .added })
    }

    func testAFailureIsRecordedWithItsReasonAndTakesNoPlace() {
        let begun = start(walk([file("1.pdf", "a"), file("2.pdf", "b")]))
        var record = begun.record
        var collection = begun.collection
        LibraryCollectionImport.settle(begun.jobs[0], outcome: .failed(reason: "Couldn't be opened", retryable: true),
                                       record: &record, collection: &collection, now: now)
        LibraryCollectionImport.settle(begun.jobs[1], outcome: .added(itemID: "item-2"), record: &record, collection: &collection, now: now)
        XCTAssertEqual(record.members.map(\.state), [.failed, .added])
        XCTAssertEqual(record.members[0].reason, "Couldn't be opened")
        XCTAssertTrue(record.members[0].retryable)
        XCTAssertEqual(collection.itemIDs, ["item-2"])
    }

    func testANewFileJoinsAmongTheListenersOwnItemsAtItsFolderPlace() {
        var record = LibraryFolderRecord(id: "c", sourcePath: path, importedAt: now, members: [
            .init(key: "1.pdf", kind: .pdf, name: "1.pdf", sha256: "a", itemID: "one", addedAt: now, state: .added),
            .init(key: "3.pdf", kind: .pdf, name: "3.pdf", sha256: "c", itemID: "three", addedAt: now, state: .added),
        ])
        // The listener added "mine" by hand, after "one".
        var collection = ItemCollection(id: "c", name: "Reading group", itemIDs: ["one", "mine", "three"], createdAt: now)
        let again = start(walk([file("1.pdf", "a"), file("2.pdf", "b"), file("3.pdf", "c")]), folders: [record], collections: [collection])
        record = again.record
        LibraryCollectionImport.settle(again.jobs[0], outcome: .added(itemID: "two"), record: &record, collection: &collection, now: now)
        XCTAssertEqual(collection.itemIDs, ["one", "two", "mine", "three"])
    }

    func testAnItemAlreadyInTheCollectionIsNotAddedTwice() {
        let begun = start(walk([file("1.pdf", "a")]))
        var record = begun.record
        var collection = begun.collection
        collection.itemIDs = ["item-1"]
        LibraryCollectionImport.settle(begun.jobs[0], outcome: .added(itemID: "item-1"), record: &record, collection: &collection, now: now)
        XCTAssertEqual(collection.itemIDs, ["item-1"])
    }

    // MARK: A write that fails (#3769 audit)

    /// File 2's write fails and file 3's succeeds: file 3's write carries file 2 into the collection too, so the stored
    /// record never says `added` for an item the stored collection lacks, and the next launch marks nothing `removed`.
    func testAFailedWriteIsCarriedByTheNextSoTheLaunchRuleRemovesNothing() {
        let begun = start(walk([file("1.pdf", "a"), file("2.pdf", "b"), file("3.pdf", "c")]))
        var storedCollection = begun.collection
        var storedRecord = begun.record
        var settling = LibraryCollectionImport.Settling(record: begun.record)
        for (index, writeSucceeds) in [(0, true), (1, false), (2, true)] {
            let job = begun.jobs[index]
            settling.settle(job, outcome: .added(itemID: job.itemID!), now: now)
            guard writeSucceeds else { continue }
            let record = settling.record
            storedCollection = settling.collection(from: storedCollection)
            storedRecord = record
            settling.didSave(record)
        }
        XCTAssertEqual(storedCollection.itemIDs, ["item-1", "item-2", "item-3"], "file 2 rode in with file 3")
        XCTAssertEqual(storedRecord.members.map(\.state), [.added, .added, .added])
        XCTAssertEqual(settling.pendingCount, 0)

        let relaunched = LibraryFolderLaunchRule.resolved(
            storedRecord, collection: storedCollection, existingItemIDs: ["item-1", "item-2", "item-3"])
        XCTAssertEqual(relaunched.record.members.map(\.state), [.added, .added, .added], "nothing marked removed")
        XCTAssertEqual(relaunched.collection, storedCollection)
    }

    /// When the last write fails, the stored record still has that member as it was before the import settled it, so
    /// the launch rule, not a stale `added`, decides: an item that was saved joins the collection.
    func testWhenTheLastWriteFailsTheLaunchRulePutsTheItemIn() {
        let begun = start(walk([file("1.pdf", "a"), file("2.pdf", "b")]))
        var settling = LibraryCollectionImport.Settling(record: begun.record)
        settling.settle(begun.jobs[0], outcome: .added(itemID: "item-1"), now: now)
        let storedCollection = settling.collection(from: begun.collection)
        let storedRecord = settling.record
        settling.didSave(storedRecord)
        settling.settle(begun.jobs[1], outcome: .added(itemID: "item-2"), now: now) // its write fails; nothing more runs
        XCTAssertEqual(settling.pendingCount, 1)

        let relaunched = LibraryFolderLaunchRule.resolved(
            storedRecord, collection: storedCollection, existingItemIDs: ["item-1", "item-2"])
        XCTAssertEqual(relaunched.collection.itemIDs, ["item-1", "item-2"])
        XCTAssertEqual(relaunched.record.members.map(\.state), [.added, .added])
    }

    /// Each write applies the pending jobs to the collection as stored at that moment, so the listener's rename or a
    /// hand-added item between two writes is kept.
    func testTheReplayLandsOnTheStoredCollectionNotACopy() {
        let begun = start(walk([file("1.pdf", "a"), file("2.pdf", "b")]))
        var settling = LibraryCollectionImport.Settling(record: begun.record)
        settling.settle(begun.jobs[0], outcome: .added(itemID: "item-1"), now: now) // its write failed
        settling.settle(begun.jobs[1], outcome: .added(itemID: "item-2"), now: now)
        var stored = begun.collection
        stored.name = "Renamed"
        stored.itemIDs = ["mine"]
        let written = settling.collection(from: stored)
        XCTAssertEqual(written.name, "Renamed")
        XCTAssertEqual(Set(written.itemIDs), ["mine", "item-1", "item-2"])
    }

    // MARK: The last line

    func testTheLastLineCountsWhatWentInAndWhatDidNot() {
        typealias I = LibraryCollectionImport
        XCTAssertEqual(I.summary(name: "X", isNew: true, added: 24, failed: 0, notAdded: 0),
                       .init(message: "Made “X” with 24 items.", kind: .success))
        XCTAssertEqual(I.summary(name: "X", isNew: true, added: 1, failed: 1, notAdded: 1),
                       .init(message: "Made “X” with 1 item. 2 couldn't be added.", kind: .warning))
        XCTAssertEqual(I.summary(name: "X", isNew: false, added: 3, failed: 0, notAdded: 0),
                       .init(message: "Added 3 items to “X”.", kind: .success))
        XCTAssertEqual(I.summary(name: "X", isNew: false, added: 0, failed: 0, notAdded: 0),
                       .init(message: "“X” is up to date.", kind: .success))
        // A re-pick of an unchanged folder whose packet was skipped the first time is still up to date (#3769 audit).
        XCTAssertEqual(I.summary(name: "X", isNew: false, added: 0, failed: 0, notAdded: 1),
                       .init(message: "“X” is up to date.", kind: .success))
        XCTAssertEqual(I.summary(name: "X", isNew: true, added: 0, failed: 2, notAdded: 0),
                       .init(message: "None of the 2 items in “X” could be added.", kind: .failure))
        XCTAssertEqual(I.summary(name: "X", isNew: false, added: 0, failed: 1, notAdded: 0).message, "The 1 item in “X” couldn't be added.")
        XCTAssertEqual(I.summary(name: "X", isNew: true, added: 0, failed: 0, notAdded: 0),
                       .init(message: "There's nothing in “X” the app can add.", kind: .failure))
    }
}
