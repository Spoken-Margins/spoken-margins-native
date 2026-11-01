import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #2818: the full app test run lost its file descriptors twice. The census names what holds them; the ledger names
/// the test class that left them open.
final class OpenDescriptorCensusTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "census-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testAnOpenFileIsListedWithItsPathUntilItIsClosed() throws {
        let file = folder.appending(path: "held-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        let before = OpenDescriptorCensus.current().count
        let handle = try FileHandle(forReadingFrom: file)
        let during = OpenDescriptorCensus.current()
        XCTAssertEqual(during.count, before + 1)
        XCTAssertTrue(during.contains { $0.target.hasSuffix(file.lastPathComponent) }, "the census names the file")
        try handle.close()
        XCTAssertEqual(OpenDescriptorCensus.current().count, before)
    }

    func testASocketOrPipeIsCountedWithAWordForWhatItIs() {
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        defer { close(ends[0]); close(ends[1]) }
        let targets = OpenDescriptorCensus.current().filter { $0.descriptor == ends[0] || $0.descriptor == ends[1] }.map(\.target)
        XCTAssertEqual(targets.count, 2)
        XCTAssertTrue(targets.allSatisfy { !$0.isEmpty }, "a descriptor with no path still gets a label")
    }

    func testGroupingCollapsesTemporaryFoldersSoLeakedStoresShowAsOneLine() {
        let one = "/tmp/summary-ownership-\(UUID().uuidString)/library.sqlite"
        let two = "/tmp/summary-ownership-\(UUID().uuidString)/library.sqlite"
        let wal = "/tmp/summary-ownership-\(UUID().uuidString)/library.sqlite-wal"
        let groups = OpenDescriptorCensus.grouped([
            OpenDescriptor(descriptor: 3, target: one),
            OpenDescriptor(descriptor: 4, target: two),
            OpenDescriptor(descriptor: 5, target: wal),
            OpenDescriptor(descriptor: 6, target: "socket"),
        ])
        XCTAssertEqual(groups.first?.kind, "summary-ownership-<id>/library.sqlite")
        XCTAssertEqual(groups.first?.count, 2)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map(\.count).reduce(0, +), 4)
    }

    func testTheLedgerNamesTheFirstClassOverBudgetAndTheClassesThatGrewIt() {
        var ledger = DescriptorLedger()
        ledger.record(group: "AlphaTests", count: 40)
        ledger.record(group: "BetaTests", count: 42)
        ledger.record(group: "GammaTests", count: 120)
        ledger.record(group: "DeltaTests", count: 150)
        XCTAssertEqual(ledger.firstOver(budget: 100)?.group, "GammaTests")
        XCTAssertNil(ledger.firstOver(budget: 150), "at the budget is within it")
        XCTAssertEqual(ledger.peak?.count, 150)
        XCTAssertEqual(ledger.biggestGrowth(atLeast: 10).map(\.group), ["GammaTests", "AlphaTests", "DeltaTests"])
        ledger.record(group: "AlphaTests", count: 39)
        XCTAssertEqual(ledger.entries.count, 4, "a class seen again keeps its place")
    }

    /// The guard's own proof: a store that is let go gives every descriptor back, and one that is kept shows up in the
    /// census. A burst of reads first, because that is what opened the extra connections in #2818.
    func testAStoreThatIsLetGoLeavesNoDescriptorsAndOneThatIsKeptDoes() throws {
        func openAndRead(_ name: String) throws -> SQLiteSessionStore {
            let store = try SQLiteSessionStore(path: folder.appending(path: name).path)
            DispatchQueue.concurrentPerform(iterations: 8) { _ in _ = try? store.listItems() }
            return store
        }
        _ = try openAndRead("warmup.sqlite") // libdispatch and SQLite may open a descriptor of their own on first use
        let baseline = OpenDescriptorCensus.current().count
        for index in 0..<10 { _ = try openAndRead("released-\(index).sqlite") }
        XCTAssertEqual(OpenDescriptorCensus.current().count, baseline, "ten released stores left descriptors open")

        let kept = try openAndRead("kept.sqlite")
        let held = OpenDescriptorCensus.current().filter { $0.target.contains("kept.sqlite") }
        XCTAssertFalse(held.isEmpty, "a live store holds its database open")
        XCTAssertLessThanOrEqual(held.count, 12, "one store should not hold more than about a dozen descriptors: \(held.map(\.target))")
        withExtendedLifetime(kept) {}
    }
}
