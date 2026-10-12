import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

@MainActor
final class PlaybackBarAccessibilityTests: XCTestCase {
    func testMountedScrubberExposesItsSliderAndEachVisibleMarginStack() async throws {
        let content = PlaybackBarContent(length: 3_600, chapterStarts: [], marks: [
            .init(id: "mine", position: 600, kind: .own),
            .init(id: "shared", position: 1_800, kind: .shared),
        ])
        let mounted = try await mount(content: content)
        defer { mounted.close() }
        let elements = try XCTUnwrap(mounted.slider.superview?.accessibilityElements,
                                    "The actual scrubber must expose Margin stacks beside its adjustable slider")
        XCTAssertEqual(elements.count, 3)
        XCTAssertTrue(elements.first as? TrackingPlaybackSlider === mounted.slider)
        let marks = elements.compactMap { $0 as? UIAccessibilityElement }
        XCTAssertEqual(marks.map(\.accessibilityLabel), ["Your Margin at 10:00", "Shared Margin at 30:00"])
        XCTAssertTrue(mounted.slider.accessibilityTraits.contains(.adjustable))
        for mark in marks {
            XCTAssertEqual(mark.accessibilityTraits, .staticText, "A displayed mark is not a seek or playback action")
            XCTAssertFalse(mark.accessibilityActivate())
        }
    }

    private func mount(content: PlaybackBarContent?) async throws -> MountedBar {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let root = PlaybackPositionSlider(value: .constant(0), range: 0...3_600,
                                          onEditingChanged: { _ in }, barContent: content)
            .accessibilityLabel("Playback position")
            .accessibilityHint("Prepared audio through 50 percent of source")
            .accessibilityValue("0:00 of 1:00:00")
            .accessibilityIdentifier("playback.scrubber")
        let host = UIHostingController(rootView: AnyView(root))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 80)
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<100 {
            host.view.layoutIfNeeded()
            if let slider = findSlider(in: host.view), slider.bounds.width > 0, slider.bounds.height > 0 {
                return MountedBar(host: host, window: window, previousKeyWindow: previous, slider: slider)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
        XCTFail("The app-hosted SwiftUI slider did not mount")
        throw MountError.sliderMissing
    }

    private func findSlider(in view: UIView) -> TrackingPlaybackSlider? {
        if let slider = view as? TrackingPlaybackSlider { return slider }
        return view.subviews.lazy.compactMap { self.findSlider(in: $0) }.first
    }

    private enum MountError: Error { case sliderMissing }

    @MainActor
    private struct MountedBar {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        let previousKeyWindow: UIWindow?
        let slider: TrackingPlaybackSlider

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
    }
}
