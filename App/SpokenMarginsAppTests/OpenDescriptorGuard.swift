import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// #2818, twice: the full `--plan app` run ran out of file descriptors in the test app (iOS gives an app 256), and
/// from then on every test that opened a database failed with "unable to open database file". Each test passed alone,
/// so something earlier in the run kept files open. This observer counts the descriptors open at the end of every test
/// class, prints the count into `xcode-tests.log`, and lists what is open the first time a class ends over the budget.
/// `ZZOpenDescriptorBudgetTests` turns that into a failure that names the class.
///
/// XCTest makes it when the bundle loads, because Config/SpokenMarginsAppTestsInfo.plist names it as NSPrincipalClass.
@objc(SMOpenDescriptorGuard)
final class OpenDescriptorGuard: NSObject, XCTestObservation, @unchecked Sendable {
    /// Descriptors the test app may have open between classes. The run starts well under half of iOS's 256 and a
    /// class that cleans up ends where it began, so this leaves room for the app's own files and fails long before
    /// SQLite does. The first run prints the real counts; move this only to match them, never to hide a leak.
    static let budget = 160

    nonisolated(unsafe) static private(set) var shared: OpenDescriptorGuard?

    private let lock = NSLock()
    private var ledger = DescriptorLedger()
    private var currentClass: String?
    private var reportedOverBudget = false
    private var releasedStoreCount = 0

    override init() {
        super.init()
        Self.shared = self
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    /// Both streams: the test app's stdout is not always forwarded into xcode-tests.log, and the unified log is.
    private static func log(_ line: String) {
        print("[fd-guard] \(line)")
        NSLog("[fd-guard] %@", line)
    }

    /// Written when a class first ends over budget. `-retry-tests-on-failure` reruns a failed test in a fresh process
    /// with an empty ledger, so the budget test also reads this file or the retry would pass and hide the leak.
    static var markerURL: URL { FileManager.default.temporaryDirectory.appending(path: "fd-guard-over-budget.txt") }

    func snapshot() -> DescriptorLedger {
        lock.lock(); defer { lock.unlock() }
        return ledger
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        let name = String(describing: type(of: testCase))
        lock.lock(); defer { lock.unlock() }
        // A full run begins with some other class; a retry of the budget test alone begins with it and keeps the marker.
        if currentClass == nil, name != "ZZOpenDescriptorBudgetTests" { try? FileManager.default.removeItem(at: Self.markerURL) }
        if currentClass == nil { Self.log("start: \(OpenDescriptorCensus.current().count) open, soft limit \(OpenDescriptorCensus.softLimit()), budget \(Self.budget)") }
        currentClass = name
        SQLiteSessionStore.trackOpenStores() // only stores opened during a test, never the host app's own
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        let name = String(describing: type(of: testCase))
        // #2818, the leak the guard named: a test that builds an app model leaves the model alive (its startup tasks
        // and observers keep it), and the model keeps its SQLite store, which holds a database, `-wal` and `-shm`
        // descriptor. Close the stores this test opened, as a store does in `deinit`, before counting.
        let released = SQLiteSessionStore.releaseTrackedStores()
        let open = OpenDescriptorCensus.current()
        lock.lock(); defer { lock.unlock() }
        releasedStoreCount += released
        let before = ledger.entries.last(where: { $0.group != name })?.count ?? 0
        ledger.record(group: name, count: open.count)
        guard open.count > Self.budget, !reportedOverBudget else { return }
        reportedOverBudget = true
        try? "\(name) ended with \(open.count) open, over the budget of \(Self.budget)".write(to: Self.markerURL, atomically: true, encoding: .utf8)
        Self.log("\(name) ended with \(open.count) open (\(before) before it), over the budget of \(Self.budget). Open now:")
        for (kind, count) in OpenDescriptorCensus.grouped(open).prefix(25) { Self.log("  \(count)x \(kind)") }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let ledger = snapshot()
        let growth = ledger.biggestGrowth(atLeast: 3).prefix(12).map { "\($0.group) +\($0.growth)" }.joined(separator: ", ")
        Self.log("released \(releasedStoreCount) test stores that outlived their test")
        Self.log("done: peak \(ledger.peak?.count ?? 0) after \(ledger.peak?.group ?? "-"); biggest growth: \(growth.isEmpty ? "none" : growth)")
    }
}

/// Fails the run when a class ended with more descriptors open than the budget, and names it. Runs after the classes
/// it judges because XCTest runs classes in name order (hence the ZZ); filtered to this class alone it has nothing to judge and passes.
final class ZZOpenDescriptorBudgetTests: XCTestCase {
    func testNoTestClassLeftMoreDescriptorsOpenThanTheBudget() throws {
        let guardObserver = try XCTUnwrap(
            OpenDescriptorGuard.shared,
            "the descriptor guard is not installed: Config/SpokenMarginsAppTestsInfo.plist must name SMOpenDescriptorGuard as NSPrincipalClass"
        )
        let ledger = guardObserver.snapshot()
        if ledger.firstOver(budget: OpenDescriptorGuard.budget) == nil,
           let earlier = try? String(contentsOf: OpenDescriptorGuard.markerURL, encoding: .utf8) {
            XCTFail("An earlier process of this run leaked descriptors (this one is a retry): \(earlier). See the [fd-guard] lines in xcode-tests.log.")
        }
        if let over = ledger.firstOver(budget: OpenDescriptorGuard.budget) {
            let jumps = ledger.biggestGrowth(atLeast: 3).prefix(10).map { "\($0.group) +\($0.growth)" }.joined(separator: ", ")
            XCTFail("""
                \(over.group) was the first test class to end with more than \(OpenDescriptorGuard.budget) file descriptors open (\(over.count)). \
                iOS gives the app 256; past that every database open fails (#2818). Biggest jumps: \(jumps). \
                What was open is in the [fd-guard] lines of xcode-tests.log. Find the object the earlier classes keep alive and release it; do not raise the limit.
                """)
        }
    }
}
