import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Mount the actual view: pure passage tests cannot catch missing SwiftUI lifecycle hooks.
@MainActor
final class PlaybackLivePassageViewTests: XCTestCase {
    private let text = "First sentence. Current sentence. Last sentence."

    func testPassageRendersWhenTheSourceIsEligibleBeforeMounting() async throws {
        let model = makeModel(target: .itemTextTTS)
        let mounted = try mount(model)
        defer { mounted.close() }
        try await waitForAppearance(mounted)

        let height = try await waitForHeight(mounted) { $0 > 130 }
        XCTAssertGreaterThan(height, 130, "The actual three sentence rows must appear from the initially empty view state")

        model.selectedItem = ItemDetailState(id: "passage-view", title: "Article", text: "One sentence.")
            .includingTimelineSource(nil)
        model.snapshot.currentTextStart = 0
        let shorterHeight = try await waitForHeight(mounted) { $0 > 30 && $0 < 100 }
        XCTAssertGreaterThan(shorterHeight, 30)
        XCTAssertLessThan(shorterHeight, 100, "Changing the retained source must rebuild the mounted passage")
    }

    func testPassageAppearsAndDisappearsAsTheMountedSourceBecomesEligible() async throws {
        let model = makeModel(target: .summaryTurnTTS)
        let mounted = try mount(model)
        defer { mounted.close() }
        try await waitForAppearance(mounted)
        XCTAssertEqual(mounted.height, 1, accuracy: 0.5, "A generated summary must not display the source passage")

        model.snapshot.targetType = TargetType.itemTextTTS.rawValue
        let visibleHeight = try await waitForHeight(mounted) { $0 > 130 }
        XCTAssertGreaterThan(visibleHeight, 130, "The same mounted view must react when source playback arrives")

        model.snapshot.targetType = TargetType.summaryTurnTTS.rawValue
        let hiddenHeight = try await waitForHeight(mounted) { $0 < 2 }
        XCTAssertEqual(hiddenHeight, 1, accuracy: 0.5)

        model.snapshot.targetType = TargetType.itemTextTTS.rawValue
        let restoredHeight = try await waitForHeight(mounted) { $0 > 130 }
        XCTAssertGreaterThan(restoredHeight, 130, "Hiding the passage must not detach its next update hook")
    }

    private func makeModel(target: TargetType) -> Gate1AppModel {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-view-\(UUID().uuidString).sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        // No bootstrap, source playback, or database reset: only the view's published inputs.
        model.selectedItem = ItemDetailState(id: "passage-view", title: "Article", text: text)
            .includingTimelineSource(nil)
        var snapshot = SessionSnapshot()
        snapshot.itemId = model.selectedItem.id
        snapshot.targetType = target.rawValue
        snapshot.status = .paused
        snapshot.currentTextStart = "First sentence. ".count
        model.snapshot = snapshot
        return model
    }

    private func mount(_ model: Gate1AppModel) throws -> MountedPassage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let appeared = Appearance()
        // The one-point sibling proves the host appeared even when the passage has no children.
        let root = VStack(spacing: 0) {
            PlaybackLivePassageView { _ in XCTFail("Mounting must not open the reader") }
            Color.clear.frame(height: 1).onAppear { appeared.value = true }
        }.environmentObject(model)
        let host = UIHostingController(rootView: AnyView(root))
        // Measure the passage itself, without the test phone's status-bar safe area.
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return MountedPassage(host: host, window: window, previousKeyWindow: previousKeyWindow, appeared: appeared)
    }

    private func waitForAppearance(_ mounted: MountedPassage) async throws {
        for _ in 0..<100 {
            if mounted.appeared.value { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The test's real SwiftUI host did not appear")
    }

    private func waitForHeight(_ mounted: MountedPassage, matching predicate: (CGFloat) -> Bool) async throws -> CGFloat {
        for _ in 0..<100 {
            let height = mounted.height
            if predicate(height) { return height }
            try await Task.sleep(for: .milliseconds(20))
        }
        return mounted.height
    }

    @MainActor
    private final class Appearance { var value = false }

    @MainActor
    private struct MountedPassage {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        let previousKeyWindow: UIWindow?
        let appeared: Appearance

        var height: CGFloat {
            host.view.layoutIfNeeded()
            return host.sizeThatFits(in: CGSize(width: 360, height: 1200)).height
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
    }
}
