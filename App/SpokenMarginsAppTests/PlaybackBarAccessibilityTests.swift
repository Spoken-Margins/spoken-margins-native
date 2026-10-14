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
        let container = try XCTUnwrap(mounted.slider.superview)
        XCTAssertFalse(container.isAccessibilityElement)
        XCTAssertFalse(container.accessibilityElementsHidden)
        let elements = try XCTUnwrap(container.accessibilityElements,
                                    "The actual scrubber must expose Margin stacks beside its adjustable slider")
        XCTAssertEqual(elements.count, 3)
        XCTAssertTrue(elements.first as? TrackingPlaybackSlider === mounted.slider)
        let marks = elements.compactMap { $0 as? UIAccessibilityElement }
        XCTAssertEqual(marks.map(\.accessibilityLabel), ["Your Margin at 10:00", "Shared Margin at 30:00"])
        XCTAssertTrue(mounted.slider.accessibilityTraits.contains(.adjustable))
        XCTAssertEqual(mounted.slider.accessibilityIdentifier, "playback.scrubber")
        XCTAssertEqual(mounted.slider.accessibilityLabel, "Playback position")
        XCTAssertEqual(mounted.slider.accessibilityValue, "0:00 of 1:00:00")
        XCTAssertEqual(mounted.slider.accessibilityHint, "Prepared audio through 50 percent of source")
        for mark in marks {
            XCTAssertEqual(mark.accessibilityTraits, .staticText, "A displayed mark is not a seek or playback action")
            XCTAssertGreaterThan(mark.accessibilityFrameInContainerSpace.width, 0)
            XCTAssertGreaterThan(mark.accessibilityFrameInContainerSpace.height, 0)
            XCTAssertTrue(mark.accessibilityContainer as? UIView === container)
            XCTAssertFalse(mark.accessibilityActivate())
        }
        XCTAssertTrue(mounted.record.events.isEmpty, "Reading a Margin must not seek")
        mounted.slider.accessibilityIncrement()
        mounted.slider.accessibilityDecrement()
        XCTAssertEqual(mounted.record.events, ["editing:true", "value:36", "editing:false", "editing:true", "value:0", "editing:false"])
    }

    func testMountedTextScrubberUsesPercentagesForItsVisibleMarks() async throws {
        let content = PlaybackBarContent(length: 1_000, chapterStarts: [], marks: [
            .init(id: "mine", position: 250, kind: .own), .init(id: "shared", position: 750, kind: .shared),
        ])
        let mounted = try await mount(content: content, unit: .characters)
        defer { mounted.close() }
        let container = try XCTUnwrap(mounted.slider.superview)
        XCTAssertEqual(try stackElements(in: container).map(\.accessibilityLabel),
                       ["Your Margin at 25 percent", "Shared Margin at 75 percent"])
    }

    func testDisabledMountedScrubberKeepsMarksReadableWithoutAdjusting() async throws {
        let content = PlaybackBarContent(length: 3_600, chapterStarts: [], marks: [.init(id: "mine", position: 600, kind: .own)])
        let mounted = try await mount(content: content, disabled: true)
        defer { mounted.close() }
        XCTAssertFalse(mounted.slider.isEnabled)
        mounted.slider.accessibilityIncrement()
        mounted.slider.accessibilityDecrement()
        XCTAssertTrue(mounted.record.events.isEmpty)
        XCTAssertEqual(mounted.slider.value, 0)
        let container = try XCTUnwrap(mounted.slider.superview)
        XCTAssertFalse(container.isAccessibilityElement)
        XCTAssertFalse(container.accessibilityElementsHidden)
        let marks = try stackElements(in: container)
        XCTAssertEqual(marks.map(\.accessibilityLabel), ["Your Margin at 10:00"])
        XCTAssertEqual(marks.first?.accessibilityTraits, .staticText)
        XCTAssertEqual(container.accessibilityElements?.count, 2)
    }

    func testCrowdedStackUsesOneElementWithTheDrawnDiamondBoundsAndUnchangedHeight() throws {
        let view = PlaybackBarAccessibilityView(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        view.slider.maximumValue = 3_600
        view.slider.barContent = PlaybackBarContent(length: 3_600, chapterStarts: [], marks:
            (0..<12).map { .init(id: "mark-\($0)", position: 600, kind: $0 < 4 ? .shared : .own) }
        )
        view.layoutIfNeeded()
        let marks = try stackElements(in: view)
        XCTAssertEqual(marks.count, 1)
        let mark = try XCTUnwrap(marks.first)
        XCTAssertEqual(mark.accessibilityLabel, "12 Margins at 10:00, 4 shared")
        let bar = try XCTUnwrap(view.slider.layer.sublayers?.first { $0.name == "playback-bar" })
        let layer = try XCTUnwrap(bar.sublayers?.first { $0.name == "playback-bar-marks" })
        let diamonds = (layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        XCTAssertEqual(diamonds.count, 4, "Three ghost layers and one counted front diamond")
        let drawn = diamonds.reduce(CGRect.null) { frame, diamond in
            frame.union((diamond.path?.boundingBoxOfPath ?? .null).insetBy(dx: -diamond.lineWidth / 2, dy: -diamond.lineWidth / 2))
        }
        XCTAssertEqual(mark.accessibilityFrameInContainerSpace, view.convert(drawn, from: view.slider))
        XCTAssertEqual(view.slider.frame, view.bounds)
        XCTAssertEqual(view.intrinsicContentSize.height, TrackingPlaybackSlider().intrinsicContentSize.height)
        XCTAssertEqual(view.sizeThatFits(CGSize(width: 300, height: 100)).height,
                       TrackingPlaybackSlider().sizeThatFits(CGSize(width: 300, height: 100)).height)
    }

    func testClockTicksAndResizePreserveElementsThenContentRemovalClearsThem() throws {
        let view = PlaybackBarAccessibilityView(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        view.positionUnit = .characters
        view.slider.maximumValue = 1_000
        view.slider.barContent = PlaybackBarContent(length: 1_000, chapterStarts: [], marks: [
            .init(id: "mine", position: 250, kind: .own), .init(id: "shared", position: 750, kind: .shared),
        ])
        view.layoutIfNeeded()
        let original = try stackElements(in: view)
        XCTAssertEqual(original.map(\.accessibilityLabel), ["Your Margin at 25 percent", "Shared Margin at 75 percent"])
        let before = try XCTUnwrap(original.first).accessibilityFrameInContainerSpace
        view.slider.value = 100
        view.slider.layoutIfNeeded()
        let ticked = try stackElements(in: view)
        XCTAssertEqual(ticked.count, original.count)
        XCTAssertTrue(zip(original, ticked).allSatisfy { pair in pair.0 === pair.1 })
        view.frame.size.width = 600
        view.layoutIfNeeded()
        let resized = try stackElements(in: view)
        XCTAssertEqual(resized.count, original.count)
        XCTAssertTrue(zip(original, resized).allSatisfy { pair in pair.0 === pair.1 })
        XCTAssertGreaterThan(try XCTUnwrap(resized.first).accessibilityFrameInContainerSpace.midX, before.midX)
        view.slider.barContent = nil
        view.slider.layoutIfNeeded()
        XCTAssertTrue(try stackElements(in: view).isEmpty)
        XCTAssertEqual(view.accessibilityElements?.count, 1)
        XCTAssertTrue(view.accessibilityElements?.first as? TrackingPlaybackSlider === view.slider)
    }

    func testResizingRegroupsAccessibilityExactlyLikeVisibleStacks() throws {
        let view = PlaybackBarAccessibilityView(frame: CGRect(x: 0, y: 0, width: 100, height: 44))
        view.slider.maximumValue = 1_000
        view.slider.barContent = PlaybackBarContent(length: 1_000, chapterStarts: [], marks: [
            .init(id: "a", position: 250, kind: .own), .init(id: "b", position: 270, kind: .shared),
        ])
        view.layoutIfNeeded()
        XCTAssertEqual(try stackElements(in: view).count, 1)
        view.frame.size.width = 600
        view.layoutIfNeeded()
        XCTAssertEqual(try stackElements(in: view).count, 2)
    }

    private func stackElements(in view: UIView) throws -> [UIAccessibilityElement] {
        try XCTUnwrap(view.accessibilityElements).compactMap { $0 as? UIAccessibilityElement }
    }

    private func mount(content: PlaybackBarContent?, unit: PlaybackBarAccessibility.PositionUnit = .seconds, disabled: Bool = false) async throws -> MountedBar {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let record = CallbackRecord()
        let root = PlaybackPositionSlider(
            value: Binding(get: { record.value }, set: { record.value = $0; record.events.append("value:\(Int($0))") }),
            range: 0...3_600,
            onEditingChanged: { record.events.append("editing:\($0)") },
            barContent: content,
            barPositionUnit: unit,
            positionAccessibilityValue: "0:00 of 1:00:00",
            positionAccessibilityHint: "Prepared audio through 50 percent of source"
        )
        .disabled(disabled)
        let host = UIHostingController(rootView: AnyView(root))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 80)
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<100 {
            host.view.layoutIfNeeded()
            if let slider = findSlider(in: host.view), slider.bounds.width > 0, slider.bounds.height > 0 {
                return MountedBar(host: host, window: window, previousKeyWindow: previous, slider: slider, record: record)
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

    @MainActor
    private final class CallbackRecord {
        var value = 0.0
        var events: [String] = []
    }

    private enum MountError: Error { case sliderMissing }

    @MainActor
    private struct MountedBar {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        let previousKeyWindow: UIWindow?
        let slider: TrackingPlaybackSlider
        let record: CallbackRecord

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
    }
}
