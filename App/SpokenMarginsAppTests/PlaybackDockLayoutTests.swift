import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Mounts the real playback screen at phone sizes and measures where the dock's playback bar lands.
/// The bar container once took every point SwiftUI offered, so the bottom dock filled the screen and
/// the Now pane above it got almost no height (#1475). Unit checks on the bare UIView passed throughout,
/// because they never asked SwiftUI what size it actually gives the bar.
@MainActor
final class PlaybackDockLayoutTests: XCTestCase {
    private static let phones: [(name: String, size: CGSize)] = [
        ("iPhone 16 class", CGSize(width: 393, height: 852)),
        ("iPhone SE class", CGSize(width: 375, height: 667)),
    ]

    func testHostedPlaybackBarIsOnlyAsTallAsTheSlider() throws {
        let sliderHeight = TrackingPlaybackSlider().intrinsicContentSize.height
        let host = UIHostingController(rootView: PlaybackPositionSlider(
            value: .constant(10), range: 0...100, onEditingChanged: { _ in },
            barContent: PlaybackBarContent(length: 100, chapterStarts: [25, 50], marks: [.init(id: "m", position: 40, kind: .own)])
        ))
        let fitted = host.sizeThatFits(in: CGSize(width: 300, height: 800))
        XCTAssertEqual(fitted.height, sliderHeight, accuracy: 4,
                       "Offered 800 points, the bar must keep the slider's height instead of stretching")
    }

    func testDockStaysCompactAndNowPaneKeepsRealHeightForAnArticle() async throws {
        for phone in Self.phones {
            let mounted = try mount(makeArticleModel(), size: phone.size)
            defer { mounted.close() }
            try await assertCompactDock(mounted, phone: phone.name, size: phone.size)
        }
    }

    func testDockStaysCompactAndNowPaneKeepsRealHeightForAPodcast() async throws {
        for phone in Self.phones {
            let mounted = try mount(makePodcastModel(), size: phone.size)
            defer { mounted.close() }
            try await assertCompactDock(mounted, phone: phone.name, size: phone.size)
        }
    }

    /// The owner scrubbed and a "loading" line appeared under Play/Pause, which pushed the whole dock up (#430).
    /// Starting playback is a status the dock must show without changing its height, so the bar stays where it was.
    func testStartingPlaybackDoesNotMoveTheDock() async throws {
        for phone in Self.phones {
            for build in [self.makeArticleModel, self.makePodcastModel] {
                let model = build()
                let mounted = try mount(model, size: phone.size)
                defer { mounted.close() }
                let restingBar = try await waitForBar(in: mounted)
                let restingTop = restingBar.convert(restingBar.bounds, to: mounted.window).minY
                var starting = model.snapshot
                starting.status = .starting
                model.snapshot = starting
                try await Task.sleep(for: .milliseconds(300))
                mounted.window.layoutIfNeeded()
                let startingBar = try await waitForBar(in: mounted)
                let startingTop = startingBar.convert(startingBar.bounds, to: mounted.window).minY
                XCTAssertEqual(startingTop, restingTop, accuracy: 0.5,
                               "\(phone.name): the bar moved from \(restingTop) to \(startingTop) while playback was starting")
            }
        }
    }

    // MARK: - Assertions

    private func assertCompactDock(_ mounted: Mounted, phone: String, size: CGSize) async throws {
        let bar = try await waitForBar(in: mounted)
        let frame = bar.convert(bar.bounds, to: mounted.window)
        let sliderHeight = TrackingPlaybackSlider().intrinsicContentSize.height
        XCTAssertEqual(frame.height, sliderHeight, accuracy: 4,
                       "\(phone): the playback bar must stay slider height; it was \(frame.height) points")
        // The dock above the bar is the pane switch (52), the chapter row (44), two 4-point gaps and 6 points of top
        // padding: 110 points at default text size. Allowing 140 keeps 30 points of slack and still asks for a
        // Now pane over 40% of the screen. The build 32 fault put the bar's top near 130 on any phone.
        let dockAboveBar: CGFloat = 110
        let estimatedDockShare = (size.height - (frame.minY - dockAboveBar)) / size.height
        print("PlaybackDockLayout \(phone) \(Int(size.width))x\(Int(size.height)): bar top \(frame.minY), bar height \(frame.height), estimated dock share \(Int((estimatedDockShare * 100).rounded()))%")
        XCTAssertGreaterThan(frame.minY, size.height * 0.4 + 140,
                             "\(phone): the dock reaches too far up the screen; the bar starts at \(frame.minY) of \(size.height)")
        XCTAssertLessThanOrEqual(frame.maxY, size.height, "\(phone): the bar must stay on screen")
    }

    // MARK: - Models

    private func makeModel() -> Gate1AppModel {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("dock-layout-\(UUID().uuidString).sqlite")
        // No bootstrap, playback or database reset: only the screen's published inputs.
        return Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
    }

    private func makeArticleModel() -> Gate1AppModel {
        let model = makeModel()
        let text = (1...60).map { "Sentence number \($0) of a long article that keeps going." }.joined(separator: " ")
        model.selectedItem = ItemDetailState(id: "dock-article", title: "A long article", text: text)
            .includingTimelineSource(nil)
        var snapshot = SessionSnapshot()
        snapshot.itemId = model.selectedItem.id
        snapshot.targetType = TargetType.itemTextTTS.rawValue
        snapshot.status = .paused
        snapshot.currentTextStart = text.count / 2
        model.snapshot = snapshot
        return model
    }

    private func makePodcastModel() -> Gate1AppModel {
        let model = makeModel()
        var item = ItemDetailState(id: "dock-podcast", title: "An episode", text: "")
        item.isNativeAudio = true
        item.mediaDurationMs = 3_600_000
        model.selectedItem = item.includingTimelineSource(nil)
        var snapshot = SessionSnapshot()
        snapshot.itemId = model.selectedItem.id
        snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
        snapshot.status = .paused
        snapshot.currentMediaTimeMs = 1_200_000
        snapshot.currentPlaybackDurationMs = 3_600_000
        model.snapshot = snapshot
        return model
    }

    // MARK: - Mounting

    private func mount(_ model: Gate1AppModel, size: CGSize) throws -> Mounted {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: AnyView(PlaybackScreen().environmentObject(model)))
        // Measure the screen itself, without the test device's own safe areas.
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return Mounted(host: host, window: window, previousKeyWindow: previousKeyWindow)
    }

    private func waitForBar(in mounted: Mounted) async throws -> PlaybackBarAccessibilityView {
        for _ in 0..<150 {
            mounted.window.layoutIfNeeded()
            if let bar = Self.find(PlaybackBarAccessibilityView.self, in: mounted.window), bar.bounds.height > 0 {
                // Let SwiftUI finish any follow-up layout pass before measuring.
                try await Task.sleep(for: .milliseconds(100))
                mounted.window.layoutIfNeeded()
                return bar
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The mounted playback screen never laid out its playback bar")
        throw BarNotFound()
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }

    private struct BarNotFound: Error {}

    @MainActor
    private struct Mounted {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        let previousKeyWindow: UIWindow?

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
    }
}
