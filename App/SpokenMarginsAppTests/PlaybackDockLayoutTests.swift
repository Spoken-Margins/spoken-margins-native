@testable import SessionKit
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

    // MARK: - Next chapter next to Skim (#1628)

    /// The owner saw a Next chapter button above the scrubber and a forward Skim control below the transport on the same
    /// screen. This mounts the real playback screen and reads which of the two it draws. The bridge is the one real state
    /// where the model's own availability pass reports forward Skim without a stored map.
    func testForwardSkimIsTheOnlyForwardControlWhenItIsOffered() async throws {
        for phone in Self.phones {
            let model = makePodcastModel(withChapters: true)
            model.snapshot.skimBridgeState = SkimBridgeState(
                direction: .forward, itemId: model.selectedItem.id, originMediaTimeMs: 1_200_000, summarySceneId: "chapter-0",
                destinationSceneId: "chapter-1", destinationMediaTimeMs: 1_800_000, summaryAssetId: "summary",
                wasSourcePlaying: false, status: .playing
            )
            XCTAssertTrue(model.canJumpToNextChapter, "precondition: a second Next chapter press can skip the summary (#569)")
            XCTAssertTrue(model.snapshot.canSkimForward, "precondition: forward Skim is offered")
            let shown = try await shownForwardControls(model, size: phone.size)
            XCTAssertTrue(shown.contains("playback.skim.forward.button"), "\(phone.name): forward Skim is missing; saw \(shown)")
            XCTAssertFalse(shown.contains("playback.nextChapter.button"),
                           "\(phone.name): Next chapter is drawn beside forward Skim; saw \(shown)")
        }
    }

    func testNextChapterStaysWhenThereIsNoForwardSkim() async throws {
        for phone in Self.phones {
            let model = makePodcastModel(withChapters: true)
            XCTAssertTrue(model.canJumpToNextChapter, "precondition: the podcast has a chapter after this one")
            XCTAssertFalse(model.snapshot.canSkimForward, "precondition: no map, so no forward Skim")
            let shown = try await shownForwardControls(model, size: phone.size)
            XCTAssertTrue(shown.contains("playback.nextChapter.button"), "\(phone.name): Next chapter is missing; saw \(shown)")
            XCTAssertFalse(shown.contains("playback.skim.forward.button"), "\(phone.name): Skim shows without a map; saw \(shown)")
        }
    }

    func testNextChapterStaysInAnArticleWithChapters() async throws {
        for phone in Self.phones {
            let model = makeArticleModel(withChapters: true)
            XCTAssertTrue(model.canJumpToNextChapter, "precondition: the article has a chapter after this one")
            let shown = try await shownForwardControls(model, size: phone.size)
            XCTAssertTrue(shown.contains("playback.nextChapter.button"), "\(phone.name): Next chapter is missing; saw \(shown)")
        }
    }

    func testNoNextChapterButtonAtTheLastChapter() async throws {
        let model = makePodcastModel(withChapters: true)
        model.snapshot.currentMediaTimeMs = 2_000_000
        XCTAssertFalse(model.canJumpToNextChapter, "precondition: nothing after the last chapter")
        let shown = try await shownForwardControls(model, size: Self.phones[0].size)
        XCTAssertFalse(shown.contains("playback.nextChapter.button"), "saw \(shown)")
    }

    /// Which of the two forward controls the mounted screen draws, by accessibility identifier.
    private func shownForwardControls(_ model: Gate1AppModel, size: CGSize) async throws -> Set<String> {
        let mounted = try mount(model, size: size)
        defer { mounted.close() }
        _ = try await waitForBar(in: mounted)
        var found: [String] = []
        var visited = Set<ObjectIdentifier>()
        Self.collectIdentifiers(from: mounted.window, into: &found, visited: &visited)
        XCTAssertTrue(found.contains("playback.dock.chapter.button"),
                      "precondition: the mounted screen's accessibility tree is readable; saw \(found)")
        return Set(found.filter { $0 == "playback.nextChapter.button" || $0 == "playback.skim.forward.button" })
    }

    /// Walks views and the accessibility elements SwiftUI vends, which are not always views.
    private static func collectIdentifiers(from node: NSObject, into found: inout [String], visited: inout Set<ObjectIdentifier>) {
        guard visited.insert(ObjectIdentifier(node)).inserted else { return }
        if node.responds(to: Selector(("accessibilityIdentifier"))),
           let identifier = node.value(forKey: "accessibilityIdentifier") as? String, !identifier.isEmpty {
            found.append(identifier)
        }
        var children: [NSObject] = []
        if let view = node as? UIView { children += view.subviews }
        children += (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        let count = node.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            children += (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
        }
        for child in children { collectIdentifiers(from: child, into: &found, visited: &visited) }
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

    private func makeArticleModel(withChapters: Bool = false) -> Gate1AppModel {
        let model = makeModel()
        let text = (1...60).map { "Sentence number \($0) of a long article that keeps going." }.joined(separator: " ")
        var article = ItemDetailState(id: "dock-article", title: "A long article", text: text)
        if withChapters {
            article.chapters = [
                Chapter(id: "a", title: "Opening", startChar: 0, endChar: text.count / 2, percent: 0),
                Chapter(id: "b", title: "Ending", startChar: text.count / 2, endChar: text.count, percent: 50),
            ]
        }
        model.selectedItem = article.includingTimelineSource(nil)
        var snapshot = SessionSnapshot()
        snapshot.itemId = model.selectedItem.id
        snapshot.targetType = TargetType.itemTextTTS.rawValue
        snapshot.status = .paused
        snapshot.currentTextStart = text.count / 2
        if withChapters { snapshot.chapterTitle = "Opening" }
        model.snapshot = snapshot
        return model
    }

    private func makePodcastModel(withChapters: Bool = false) -> Gate1AppModel {
        let model = makeModel()
        var item = ItemDetailState(id: "dock-podcast", title: "An episode", text: "")
        item.isNativeAudio = true
        item.mediaDurationMs = 3_600_000
        if withChapters {
            // The snapshot sits at 1,200,000 ms, so the next chapter starts at 1,800,000 ms.
            item.mediaChapters = [("chapter-0", 0), ("chapter-1", 1_800_000)].map {
                MediaTimelineChapter(id: $0.0, title: "Chapter \($0.0)", startMs: $0.1, transcriptSegmentId: "segment-\($0.0)")
            }
        }
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
