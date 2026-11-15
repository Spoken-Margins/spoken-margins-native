import Foundation
import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// Fails the running app-hosted test when a sheet or cover in it is built again while open (#4337). Each test starts
/// from an empty ledger, so a screen one test closed is never compared with the next test's. A test that rebuilds a
/// screen on purpose sets `ScreenRebuildTripwire.shared.onRebuild` itself after it starts.
///
/// XCTest finds it through `OpenDescriptorGuard`, the bundle's principal class, which installs it when the bundle loads.
@objc(SMScreenRebuildFailsTheTest)
final class ScreenRebuildFailsTheTest: NSObject, XCTestObservation, @unchecked Sendable {
    nonisolated(unsafe) static private(set) var shared: ScreenRebuildFailsTheTest?

    static func install() {
        guard shared == nil else { return }
        let observer = ScreenRebuildFailsTheTest()
        shared = observer
        XCTestObservationCenter.shared.addTestObserver(observer)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        MainActor.assumeIsolated {
            ScreenRebuildTripwire.shared.reset()
            ScreenRebuildTripwire.shared.onRebuild = { [weak testCase] rebuild in
                testCase?.record(XCTIssue(
                    type: .assertionFailure,
                    compactDescription: "A screen was built again while open (#4337): \(rebuild.presentation), "
                        + "\(rebuild.gapMs == 0 ? "while the first still showed" : "\(rebuild.gapMs) ms after the first went")"))
            }
        }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        MainActor.assumeIsolated { ScreenRebuildTripwire.shared.onRebuild = nil }
    }
}
