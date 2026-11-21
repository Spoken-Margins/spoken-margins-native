import Foundation
import XCTest

extension XCTestCase {
    /// Runs `call` on another thread and waits for it to come back while the test still holds whatever the slow work is
    /// blocked on (a semaphore it never signalled, a parked pipe). A call that waits for that work cannot return until
    /// the test lets go, so this fails on state, "still waiting on the held work", not on a clock that a busy runner can
    /// miss (#4573: a 2 s ceiling on a Library read took 2.26 s on a hosted Mac and held the merge queue for an hour).
    ///
    /// The ceiling only keeps a regression from hanging the run, so it is far above any normal time. `onTimeout` runs
    /// when the call is still blocked at the ceiling: let the held work go there, so the stuck thread can end.
    @discardableResult
    func assertReturnsWhileHeld(
        _ what: String,
        ceiling: TimeInterval = 30,
        onTimeout: () -> Void = {},
        file: StaticString = #filePath,
        line: UInt = #line,
        _ call: @escaping @Sendable () -> Void
    ) -> Bool {
        let returned = XCTestExpectation(description: "\(what) returned while the slow work was still held")
        DispatchQueue.global(qos: .userInitiated).async {
            call()
            returned.fulfill()
        }
        guard XCTWaiter().wait(for: [returned], timeout: ceiling) == .completed else {
            XCTFail("still waiting on the held work: \(what)", file: file, line: line)
            onTimeout()
            return false
        }
        return true
    }
}
