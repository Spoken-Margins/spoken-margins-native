import XCTest
@testable import SessionKit

final class PreparedAudioCompletionTests: XCTestCase {
    func testOnlyAPreparationStillWantedMayBeMarkedReady() {
        // #2134: assembly takes a while; a Stop, a failure or a voice change that landed meanwhile wins.
        let allowed: Set<PreparedAudioState> = [.preparing, .pausedForThermal, .readyOffline]
        let all: [PreparedAudioState] = [.notPrepared, .preparing, .pausedForThermal, .readyOffline, .needsRepreparation, .stopped, .failed]
        for state in all {
            XCTAssertEqual(PreparedAudioEnqueue.mayComplete(state), allowed.contains(state), "\(state)")
        }
    }
}
