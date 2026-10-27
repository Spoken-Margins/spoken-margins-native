import XCTest
@testable import SessionKitSupertonic

/// #2702: Supertonic caps its ONNX Runtime threads; overrides are DEBUG-only.
final class SupertonicTuningTests: XCTestCase {
    func testDefaultsWhenOverridesNotAllowed() {
        let env = [SupertonicTuning.threadsOverrideKey: "6", SupertonicTuning.stepsOverrideKey: "5"]
        XCTAssertEqual(SupertonicTuning.intraOpThreads(environment: env, allowOverrides: false), 2)
        XCTAssertEqual(SupertonicTuning.synthesisSteps(requested: 8, environment: env, allowOverrides: false), 8)
    }

    func testOverridesApplyWhenAllowed() {
        let env = [SupertonicTuning.threadsOverrideKey: "4", SupertonicTuning.stepsOverrideKey: "5"]
        XCTAssertEqual(SupertonicTuning.intraOpThreads(environment: env, allowOverrides: true), 4)
        XCTAssertEqual(SupertonicTuning.synthesisSteps(requested: 8, environment: env, allowOverrides: true), 5)
    }

    func testBadOverridesFallBack() {
        for bad in ["", "abc", "0", "-1", "99", "2.5"] {
            let env = [SupertonicTuning.threadsOverrideKey: bad, SupertonicTuning.stepsOverrideKey: bad]
            XCTAssertEqual(SupertonicTuning.intraOpThreads(environment: env, allowOverrides: true), 2, bad)
            XCTAssertEqual(SupertonicTuning.synthesisSteps(requested: 8, environment: env, allowOverrides: true), 8, bad)
        }
        XCTAssertEqual(SupertonicTuning.intraOpThreads(environment: [:], allowOverrides: true), 2)
    }
}
