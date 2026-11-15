import Foundation
import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// Fails the running test when a sheet or full-screen cover is built again while it is open (#4337).
///
/// Every sheet and cover in the app goes through `trackedSheet` or `trackedFullScreenCover`, which report to
/// `PresentationTracker`. A presentation that is dismissed and presented again by itself builds a new screen: the
/// listener sees it flash and loses what was open on it. It reached the owner's phone as #2831, #4091 (twice) and
/// #3891, and no test saw it, because the redraw probes count body runs and not builds. This observer gives the
/// tracker a handler that records an issue on the test that was running, so any test that mounts a screen now fails on a
/// rebuild, whatever else it was checking. It forgets the screens at the start of each test, so one test's covers
/// can't make the next one's look rebuilt.
///
/// XCTest finds it through `OpenDescriptorGuard`, the bundle's principal class, which installs it when the bundle loads.
@objc(SMPresentationRebuildGuard)
final class PresentationRebuildGuard: NSObject, XCTestObservation, @unchecked Sendable {
    nonisolated(unsafe) static private(set) var shared: PresentationRebuildGuard?

    private let lock = NSLock()
    private var running: XCTestCase?

    static func install() {
        guard shared == nil else { return }
        let observer = PresentationRebuildGuard()
        shared = observer
        XCTestObservationCenter.shared.addTestObserver(observer)
        observer.attach()
    }

    /// Makes a rebuild fail the running test. A test that rebuilds a screen on purpose replaces the handler to catch the
    /// rebuild itself, and calls this when it is done.
    func attach() {
        PresentationTracker.shared.onRebuild = { [weak self] rebuild in self?.fail(rebuild) }
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        PresentationTracker.shared.reset()
        lock.lock(); defer { lock.unlock() }
        running = testCase
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        lock.lock(); defer { lock.unlock() }
        running = nil
    }

    private func fail(_ rebuild: PresentationLedger.Rebuild) {
        lock.lock()
        let test = running
        lock.unlock()
        test?.record(XCTIssue(
            type: .assertionFailure,
            compactDescription: "Screen rebuilt while open: \(rebuild.description). A sheet or cover that builds twice flashes and loses what was open on it (#4337)."
        ))
    }
}
