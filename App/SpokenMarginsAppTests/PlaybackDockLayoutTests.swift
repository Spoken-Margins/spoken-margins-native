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
            let builds: [() -> Gate1AppModel] = [{ self.makeArticleModel() }, { self.makePodcastModel() }]
            for build in builds {
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

    /// The owner saw a Next chapter button above the scrubber and a forward Skim control below the transport on the
    /// same screen. The model decides which of them the dock draws; these pin that decision for each state the issue
    /// names. The first run read the mounted screen's accessibility tree for the buttons and could not find anything in
    /// it (all four such tests failed, including the ones that expect a button), so the screen is not mounted here.
    private func forwardSkimBridge(for model: Gate1AppModel) -> SkimBridgeState {
        SkimBridgeState(
            direction: .forward, itemId: model.selectedItem.id, originMediaTimeMs: 1_200_000, summarySceneId: "chapter-0",
            destinationSceneId: "chapter-1", destinationMediaTimeMs: 1_800_000, summaryAssetId: "summary",
            wasSourcePlaying: false, status: .playing
        )
    }

    func testForwardSkimIsTheOnlyForwardControlWhenItIsOffered() {
        let model = makePodcastModel(withChapters: true)
        model.snapshot.skimBridgeState = forwardSkimBridge(for: model)
        XCTAssertTrue(model.snapshot.canSkimForward, "precondition: forward Skim is offered")
        XCTAssertTrue(model.showsSkimRow)
        XCTAssertTrue(model.canJumpToNextChapter, "the Lock Screen and external commands keep Next chapter (#569)")
        XCTAssertFalse(model.showsNextChapterButton, "the chapter row must not draw a second forward control")
    }

    func testNextChapterStaysWhenThereIsNoForwardSkim() {
        let model = makePodcastModel(withChapters: true)
        XCTAssertFalse(model.snapshot.canSkimForward, "precondition: no map, so no forward Skim")
        XCTAssertFalse(model.showsSkimRow)
        XCTAssertTrue(model.canJumpToNextChapter)
        XCTAssertTrue(model.showsNextChapterButton)
    }

    func testNextChapterStaysInAnArticleWithChapters() {
        let model = makeArticleModel(withChapters: true)
        XCTAssertTrue(model.canJumpToNextChapter, "precondition: the article has a chapter after this one")
        XCTAssertFalse(model.showsSkimRow, "an article has no Skim row")
        XCTAssertTrue(model.showsNextChapterButton)
    }

    func testNoNextChapterButtonAtTheLastChapter() {
        let model = makePodcastModel(withChapters: true)
        model.snapshot.currentMediaTimeMs = 2_000_000
        XCTAssertFalse(model.canJumpToNextChapter, "precondition: nothing after the last chapter")
        XCTAssertFalse(model.showsNextChapterButton)
    }

    /// The real chapter row, laid out: with the button asked for the row is a button wider (44-point minimum) than
    /// without it, so what the model decides is what the dock draws.
    func testChapterRowDrawsTheButtonOnlyWhenAsked() {
        func idealWidth(showsNextChapterButton: Bool) -> CGFloat {
            let row = PlaybackChapterRowView(
                title: "Chapter 2", sourceTitle: "An episode", showsNextChapterButton: showsNextChapterButton,
                showItem: {}, nextChapter: {}
            )
            return UIHostingController(rootView: row.fixedSize(horizontal: true, vertical: false))
                .sizeThatFits(in: CGSize(width: 2_000, height: 200)).width
        }
        let with = idealWidth(showsNextChapterButton: true)
        let without = idealWidth(showsNextChapterButton: false)
        XCTAssertGreaterThanOrEqual(with - without, 44, "the Next chapter button added \(with - without) points to the row")
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
