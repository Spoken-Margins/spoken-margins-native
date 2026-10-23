import Foundation
import XCTest
@testable import SessionKit

/// #2485 audit: a Lock Screen Mark written while the screen reads the waiting Marks is never lost.
final class LiveSessionMarkInboxTests: XCTestCase {
    /// A store that lets a test write a Mark at the worst moment: after the reader has listed the keys and
    /// before it has cleared them.
    private final class RacingStore: LiveSessionMarkStore {
        var values: [String: Double] = [:]
        var afterFirstRead: (() -> Void)?

        func markKeys(prefix: String) -> [String] { values.keys.filter { $0.hasPrefix(prefix) }.sorted() }
        func markTime(forKey key: String) -> Double? {
            defer {
                let hook = afterFirstRead
                afterFirstRead = nil
                hook?()
            }
            return values[key]
        }
        func setMarkTime(_ time: Double, forKey key: String) { values[key] = time }
        func removeMark(forKey key: String) { values[key] = nil }
    }

    func testAMarkWrittenDuringADrainWaitsForTheNextOne() {
        let store = RacingStore()
        let inbox = LiveSessionMarkInbox(store: store)
        inbox.enqueue(Date(timeIntervalSince1970: 100))
        store.afterFirstRead = { inbox.enqueue(Date(timeIntervalSince1970: 200)) }
        XCTAssertEqual(inbox.drain(), [Date(timeIntervalSince1970: 100)])
        XCTAssertEqual(inbox.drain(), [Date(timeIntervalSince1970: 200)])
        XCTAssertEqual(inbox.drain(), [])
    }

    func testMarksComeBackOldestFirstAndTheBufferDropsTheOldest() {
        let store = RacingStore()
        let inbox = LiveSessionMarkInbox(store: store)
        for second in 0...LiveSessionMarkInbox.maximumBufferedMarks {
            inbox.enqueue(Date(timeIntervalSince1970: Double(second)))
        }
        let drained = inbox.drain()
        XCTAssertEqual(drained.count, LiveSessionMarkInbox.maximumBufferedMarks)
        XCTAssertEqual(drained.first, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(drained, drained.sorted())
    }

    func testUserDefaultsKeepsEachMarkSeparately() throws {
        let suite = "mark-inbox-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let inbox = LiveSessionMarkInbox(store: defaults)
        inbox.enqueue(Date(timeIntervalSince1970: 5))
        inbox.enqueue(Date(timeIntervalSince1970: 3))
        XCTAssertEqual(inbox.drain(), [Date(timeIntervalSince1970: 3), Date(timeIntervalSince1970: 5)])
        XCTAssertEqual(inbox.drain(), [])
    }
}
