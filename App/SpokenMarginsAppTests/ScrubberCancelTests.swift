import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #1930: a touch that slides far off the scrubber and lifts there seeks nowhere.
@MainActor
final class ScrubberCancelTests: XCTestCase {
    private final class FakeTouch: UILongPressGestureRecognizer {
        var fakeState: UIGestureRecognizer.State = .possible
        var fakePoint: CGPoint = .zero
        override var state: UIGestureRecognizer.State {
            get { fakeState }
            set { fakeState = newValue }
        }
        override func location(in view: UIView?) -> CGPoint { fakePoint }
    }

    private func makeSlider(log: @escaping (String) -> Void) -> TrackingPlaybackSlider {
        let slider = TrackingPlaybackSlider(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        slider.minimumValue = 0
        slider.maximumValue = 100
        slider.setValue(40, animated: false)
        slider.onValue = { log("value \(Int($0))") }
        slider.onEditing = { log("editing \($0)") }
        slider.onCancelled = { log("cancelled") }
        slider.layoutIfNeeded()
        return slider
    }

    private func drive(_ slider: TrackingPlaybackSlider, _ steps: [(UIGestureRecognizer.State, CGPoint)]) {
        let touch = FakeTouch()
        for (state, point) in steps {
            touch.fakeState = state
            touch.fakePoint = point
            slider.trackTouch(touch)
        }
    }

    func testLiftingFarAboveTheBarRestoresThePositionAndSeeksNowhere() {
        var log: [String] = []
        let slider = makeSlider { log.append($0) }
        drive(slider, [(.began, CGPoint(x: 250, y: 22)), (.changed, CGPoint(x: 250, y: -90)), (.ended, CGPoint(x: 250, y: -90))])
        XCTAssertEqual(Int(slider.value), 40, "back where it was")
        XCTAssertTrue(log.contains("cancelled"))
        XCTAssertFalse(log.contains("editing false"), "ending editing is what commits a seek")
        XCTAssertFalse(slider.gestureActive)
    }

    func testLiftingOnTheBarStillCommits() {
        var log: [String] = []
        let slider = makeSlider { log.append($0) }
        drive(slider, [(.began, CGPoint(x: 250, y: 22)), (.ended, CGPoint(x: 250, y: 40))])
        XCTAssertGreaterThan(slider.value, 60)
        XCTAssertEqual(log.last, "editing false")
        XCTAssertFalse(log.contains("cancelled"))
    }

    func testSlidingBackOntoTheBarFollowsTheFingerAgain() {
        var log: [String] = []
        let slider = makeSlider { log.append($0) }
        drive(slider, [(.began, CGPoint(x: 250, y: 22)), (.changed, CGPoint(x: 250, y: 200)), (.changed, CGPoint(x: 60, y: 22))])
        XCTAssertLessThan(slider.value, 40)
        XCTAssertTrue(slider.gestureActive)
    }

    func testASystemCancelledTouchDoesNotSeek() {
        var log: [String] = []
        let slider = makeSlider { log.append($0) }
        drive(slider, [(.began, CGPoint(x: 250, y: 22)), (.cancelled, CGPoint(x: 250, y: 22))])
        XCTAssertEqual(Int(slider.value), 40)
        XCTAssertFalse(log.contains("editing false"))
        XCTAssertTrue(log.contains("cancelled"))
    }
}
