import XCTest
@testable import SessionKit

final class PocketDeviceGateTests: XCTestCase {
    private func measure(audio: Double, render: Double) -> PocketRenderMeasurement {
        PocketRenderMeasurement(audioSeconds: audio, renderSeconds: render)
    }

    func testThresholdIsTheFloorUntilThePhoneNumberIsKnown() {
        XCTAssertEqual(PocketDeviceGate().threshold, 2)
    }

    func testFastPhoneIsOffered() {
        XCTAssertEqual(PocketDeviceGate().decide(measure(audio: 6, render: 2)), .offer)
    }

    func testSlowPhoneIsNotOffered() {
        XCTAssertEqual(PocketDeviceGate().decide(measure(audio: 6, render: 6)), .tooSlow(speed: 1, threshold: 2))
    }

    func testBorderlineAtTheThresholdIsOffered() {
        XCTAssertEqual(PocketDeviceGate().decide(measure(audio: 6, render: 3)), .offer)
    }

    func testBorderlineJustBelowTheThresholdIsNotOffered() {
        XCTAssertEqual(PocketDeviceGate().decide(measure(audio: 6, render: 3.01)), .tooSlow(speed: 6 / 3.01, threshold: 2))
    }

    func testLowerPhoneNumberLowersTheThresholdByTheMargin() {
        let gate = PocketDeviceGate(referencePhoneSpeed: 1.6, margin: 0.25)
        XCTAssertEqual(gate.threshold, 1.35, accuracy: 1e-9)
        XCTAssertEqual(gate.decide(measure(audio: 6, render: 4)), .offer)
        XCTAssertEqual(gate.decide(measure(audio: 6, render: 5)), .tooSlow(speed: 1.2, threshold: gate.threshold))
    }

    func testFasterPhoneNumberNeverRaisesThresholdAboveTheFloor() {
        XCTAssertEqual(PocketDeviceGate(referencePhoneSpeed: 5).threshold, 2)
        XCTAssertEqual(PocketDeviceGate(referencePhoneSpeed: 2.1, margin: 0.25).threshold, 1.85, accuracy: 1e-9)
    }

    func testBadReferenceOrMarginFallsBackSafely() {
        XCTAssertEqual(PocketDeviceGate(referencePhoneSpeed: .nan).threshold, 2)
        XCTAssertEqual(PocketDeviceGate(referencePhoneSpeed: 0).threshold, 2)
        XCTAssertEqual(PocketDeviceGate(referencePhoneSpeed: -3).threshold, 2)
        XCTAssertEqual(PocketDeviceGate(referencePhoneSpeed: 1.5, margin: -4).threshold, 1.5)
        XCTAssertEqual(PocketDeviceGate(referencePhoneSpeed: 1.5, margin: .nan).threshold, 1.5)
        XCTAssertEqual(PocketDeviceGate(referencePhoneSpeed: 1.5, margin: .infinity).threshold, 1.5)
    }

    func testThresholdNeverDropsBelowRealTime() {
        XCTAssertEqual(PocketDeviceGate(referencePhoneSpeed: 0.1, margin: 0.5).threshold, 1)
        XCTAssertEqual(PocketDeviceGate(referencePhoneSpeed: 1.1, margin: 0.25).threshold, 1)
        XCTAssertEqual(PocketDeviceGate(referencePhoneSpeed: 0.1).decide(measure(audio: 6, render: 10)), .tooSlow(speed: 0.6, threshold: 1))
    }

    func testUnusableMeasurementsAreInconclusiveNotOffered() {
        let gate = PocketDeviceGate()
        XCTAssertEqual(gate.decide(measure(audio: 6, render: 0)), .inconclusive)
        XCTAssertEqual(gate.decide(measure(audio: 6, render: -1)), .inconclusive)
        XCTAssertEqual(gate.decide(measure(audio: 0, render: 1)), .inconclusive)
        XCTAssertEqual(gate.decide(measure(audio: .nan, render: 1)), .inconclusive)
        XCTAssertEqual(gate.decide(measure(audio: 6, render: .infinity)), .inconclusive)
        XCTAssertEqual(gate.decide(measure(audio: 2.9, render: 0.1)), .inconclusive, "too little audio to trust")
        XCTAssertEqual(gate.decide(measure(audio: 3, render: 1)), .offer, "exactly the minimum audio is enough")
    }
}
