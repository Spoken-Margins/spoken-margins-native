import XCTest
@testable import SessionKit

final class OwnedWorkRegistryTests: XCTestCase {
    func testAnOldJobEndingAfterARebuildLeavesTheNewJobsMarkAlone() {
        var registry = OwnedWorkRegistry<String>()
        let old = registry.begin("item").token
        registry.attach("old task", to: "item", token: old)

        // The engine rebuild empties the registry and cancels what was running.
        XCTAssertEqual(registry.removeAll(), ["old task"])
        XCTAssertFalse(registry.contains("item"))

        // A new trigger for the same item starts one job...
        let new = registry.begin("item").token
        registry.attach("new task", to: "item", token: new)
        // ...and the old job ending must not clear its mark, or a third job could start.
        XCTAssertFalse(registry.finish("item", token: old))
        XCTAssertTrue(registry.contains("item"))
        XCTAssertTrue(registry.finish("item", token: new))
        XCTAssertFalse(registry.contains("item"))
    }

    func testBeginningAgainHandsBackTheEarlierJobToCancel() {
        var registry = OwnedWorkRegistry<String>()
        let first = registry.begin("item")
        XCTAssertNil(first.replaced)
        registry.attach("first", to: "item", token: first.token)
        let second = registry.begin("item")
        XCTAssertEqual(second.replaced, "first")
        // A handle attached by the replaced job's starter after the fact is dropped, not stored.
        registry.attach("late first", to: "item", token: first.token)
        registry.attach("second", to: "item", token: second.token)
        XCTAssertEqual(registry.remove("item"), "second")
    }

    func testRemovingKeysReturnsOnlyTheHandlesThatWereAttached() {
        var registry = OwnedWorkRegistry<Int>()
        let a = registry.begin("a").token
        _ = registry.begin("b") // no handle attached yet
        registry.attach(1, to: "a", token: a)
        XCTAssertEqual(registry.remove(["a", "b", "missing"]), [1])
        XCTAssertEqual(registry.keys, [])
    }

    func testFinishingTwiceOrAfterRemovalIsHarmless() {
        var registry = OwnedWorkRegistry<Int>()
        let token = registry.begin("item").token
        XCTAssertTrue(registry.finish("item", token: token))
        XCTAssertFalse(registry.finish("item", token: token))
        let next = registry.begin("item").token
        registry.remove("item")
        XCTAssertFalse(registry.finish("item", token: next))
        XCTAssertFalse(registry.contains("item"))
    }
}
