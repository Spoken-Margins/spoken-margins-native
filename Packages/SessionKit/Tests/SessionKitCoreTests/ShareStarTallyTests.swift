import XCTest
@testable import SessionKit

/// #4173 PR 2: the counts behind the `share.selection` Diagnostics line. Every row is a screen the star can come from,
/// turned on or off, and what a relaunch or a send does to the count.
final class ShareStarTallyTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "ShareStarTallyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // Only the name crosses into the teardown closure: UserDefaults itself is a data-race error in Swift 6.
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testEachScreenCountsUnderItsOwnBucket() {
        let rows: [(ShareStarPlace, ShareStarTally)] = [
            (.now, ShareStarTally(starsNow: 1)),
            (.playerMargins, ShareStarTally(starsPlayerMargins: 1)),
            (.detail, ShareStarTally(starsElsewhere: 1)),
            (.manage, ShareStarTally(starsElsewhere: 1)),
            (.marginsTab, ShareStarTally(starsElsewhere: 1))
        ]
        XCTAssertEqual(Set(rows.map(\.0)), Set(ShareStarPlace.allCases), "a new screen needs a row here")
        for (place, expected) in rows {
            var tally = ShareStarTally()
            tally.add(place, turnedOn: true)
            XCTAssertEqual(tally, expected, "\(place)")
        }
    }

    func testEveryTurnToOffCountsAsOneUnstarWhateverTheScreen() {
        for place in ShareStarPlace.allCases {
            var tally = ShareStarTally()
            tally.add(place, turnedOn: false)
            XCTAssertEqual(tally, ShareStarTally(unstars: 1), "\(place)")
        }
    }

    func testResetEmptiesEveryCount() {
        var tally = ShareStarTally(starsNow: 2, starsPlayerMargins: 1, starsElsewhere: 3, unstars: 4)
        XCTAssertFalse(tally.isEmpty)
        tally.reset()
        XCTAssertTrue(tally.isEmpty)
    }

    func testTheTallySurvivesANewStoreOverTheSameDefaults() {
        let defaults = freshDefaults()
        ShareStarTallyStore(defaults: defaults).record(.now, turnedOn: true)
        ShareStarTallyStore(defaults: defaults).record(.now, turnedOn: true)
        ShareStarTallyStore(defaults: defaults).record(.detail, turnedOn: false)
        XCTAssertEqual(ShareStarTallyStore(defaults: defaults).load(), ShareStarTally(starsNow: 2, unstars: 1))
    }

    func testResetAfterASendStartsTheNextCountFromZero() {
        let defaults = freshDefaults()
        let store = ShareStarTallyStore(defaults: defaults)
        store.record(.playerMargins, turnedOn: true)
        store.reset()
        XCTAssertEqual(store.load(), ShareStarTally())
        XCTAssertEqual(store.record(.now, turnedOn: true), ShareStarTally(starsNow: 1))
    }

    func testAnUnreadableStoredValueCountsAsEmptyAndStarringStillWorks() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: ShareStarTallyStore.key)
        let store = ShareStarTallyStore(defaults: defaults)
        XCTAssertEqual(store.load(), ShareStarTally())
        XCTAssertEqual(store.record(.now, turnedOn: true), ShareStarTally(starsNow: 1))
        defaults.set("a string", forKey: ShareStarTallyStore.key)
        XCTAssertEqual(store.load(), ShareStarTally())
    }

    func testTheStoredShapeHoldsOnlyFourCounts() throws {
        let data = try JSONEncoder().encode(ShareStarTally(starsNow: 1, starsPlayerMargins: 2, starsElsewhere: 3, unstars: 4))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(Set(object.keys), ["starsNow", "starsPlayerMargins", "starsElsewhere", "unstars"])
    }
}
