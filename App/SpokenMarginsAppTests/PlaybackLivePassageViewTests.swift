import SessionKit
import SessionKitPersistence
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
        XCTAssertGreaterThan(height, 130, "The actual sentence rows must appear from the initially empty view state")

        model.selectedItem = ItemDetailState(id: "passage-view", title: "Article", text: "One sentence.")
            .includingTimelineSource(nil)
        model.snapshot.currentTextStart = 0
        let shorterHeight = try await waitForHeight(mounted) { $0 > 30 && $0 < 125 }
        XCTAssertGreaterThan(shorterHeight, 30)
        XCTAssertLessThan(shorterHeight, 125, "Changing the retained source must rebuild the mounted passage")
    }

    func testPassageAppearsAsTheMountedSourceBecomesEligibleAndStaysWhileAMarginOrSummaryPlaysOnTheItem() async throws {
        let model = makeModel(target: .summaryTurnTTS)
        let mounted = try mount(model)
        defer { mounted.close() }
        try await waitForAppearance(mounted)
        XCTAssertEqual(mounted.height, 1, accuracy: 0.5, "A generated summary must not display the source passage before the source has played")

        model.snapshot.targetType = TargetType.itemTextTTS.rawValue
        let visibleHeight = try await waitForHeight(mounted) { $0 > 130 }
        XCTAssertGreaterThan(visibleHeight, 130, "The same mounted view must react when source playback arrives")

        // A summary on this item: the scene stays with its last sentence lit, so a long list never loses the listener's place (#4453).
        model.snapshot.targetType = TargetType.summaryTurnTTS.rawValue
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(mounted.height, 130)

        // Another item playing hides it, as before.
        model.snapshot.itemId = "another-item"
        let hiddenHeight = try await waitForHeight(mounted) { $0 < 2 }
        XCTAssertEqual(hiddenHeight, 1, accuracy: 0.5)

        model.snapshot.itemId = model.selectedItem.id
        model.snapshot.targetType = TargetType.itemTextTTS.rawValue
        let restoredHeight = try await waitForHeight(mounted) { $0 > 130 }
        XCTAssertGreaterThan(restoredHeight, 130, "Hiding the passage must not detach its next update hook")
    }

    /// #4453: a scene of 9,000 sentences (a 1.1 MB book with no chapters) draws only the rows near the screen, and a
    /// tick that stays in the same sentence draws none. Structural and not timed: it counts row bodies.
    func testALongSceneRealizesFewRowsAndASameSentenceTickDrawsNone() async throws {
        let text = (1...9_000).map { "This is sentence number \($0) of a very long book." }.joined(separator: " ")
        let model = makeModel(target: .itemTextTTS, text: text)
        let middle = (text as NSString).range(of: "sentence number 4500 ").location
        model.snapshot.currentTextStart = middle
        NowSceneRowCounter.reset()
        let mounted = try mount(model, inScrollView: true)
        defer { mounted.close() }
        try await waitForAppearance(mounted)
        try await Task.sleep(for: .seconds(2))
        let realizedIDs = NowSceneRowCounter.sentences
        let realized = realizedIDs.count
        XCTAssertGreaterThan(realized, 0, "The rows near the lit sentence are drawn")
        // Distinct sentences, not body runs: a publish elsewhere that redraws the visible rows once more is not a row
        // realized. Counting bodies read 106 and 123 in the 11-18 batch run, with nothing in this view changed.
        // The limit is a fraction of the scene, not a count picked from one quiet run (#4664): the hosted main-t3 runs
        // read 145 and 151 distinct rows of 9,000, because LazyVStack realizes a lead-in beyond the visible rows, and
        // how far it reads ahead varies with load. What this test guards is a list that is not lazy at all (9,000 rows)
        // or that realizes the rows it scrolls past (thousands), so the limit sits at 5%, three times the highest
        // reading so far and twenty times below either failure. The message carries the span so the next reading
        // shows where the rows were.
        let limit = 9_000 / 20
        XCTAssertLessThan(
            realized, limit,
            "Fewer than \(limit) of 9,000 rows are realized (\(realized) were, at text offsets \(realizedIDs.min() ?? -1) to \(realizedIDs.max() ?? -1); the lit one is at \(middle))"
        )
        let drawn = NowSceneRowCounter.bodies

        // The same sentence, a few Characters on: nothing is drawn again.
        model.snapshot.currentTextStart = middle + 3
        // fixed-sleep ok: the claim is that this tick draws no row, and no signal marks a row that is never drawn; the
        // update path is one published change and one main-actor hop, which 600 ms covers many times over.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(NowSceneRowCounter.bodies, drawn, "A tick that keeps the same sentence draws no row")
    }

    // MARK: Table and figure cards (#4588)

    /// A table and a figure with a picture each stand in the scene before the sentence that holds their caption, in the
    /// order of the text, and are drawn there. An article has no document and so no cards.
    func testAPDFsPicturesAreDrawnBeforeTheirCaptionsAndAnArticleDrawsNone() async throws {
        let itemID = "passage-clips-\(UUID().uuidString)"
        let parts: [(id: String, role: StructuredDocument.Role, text: String)] = [
            ("a", .body, "Intro sentence one. Intro sentence two."),
            ("t", .table, "a 1 2\nb 3 4"),
            ("b", .body, "Table 1. Results by arm. More body here."),
            ("fig", .figureText, "axis"),
            ("c", .body, "Figure 2. Accuracy by model. Last sentence here."),
        ]
        var text = ""
        var segments: [StructuredDocument.Segment] = []
        for part in parts {
            if !text.isEmpty { text += "\n\n" }
            segments.append(.init(id: part.id, role: part.role, range: .init(start: text.count, length: part.text.count)))
            text += part.text
        }
        let floats: [StructuredDocument.Float] = [
            .init(id: "t1", kind: .table, label: nil, pageIndex: 0, bounds: .init(x: 0.1, y: 0.5, width: 0.6, height: 0.2),
                  captionSegmentId: nil, textSegmentId: "t"),
            .init(id: "f1", kind: .figure, label: nil, pageIndex: 0, bounds: .init(x: 0.1, y: 0.2, width: 0.6, height: 0.2),
                  captionSegmentId: nil, textSegmentId: "fig"),
        ]
        let document = StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
            text: text, segments: segments, markers: [], floats: floats)

        let model = makeModel(target: .itemTextTTS, text: text)
        model.selectedItem = ItemDetailState(id: itemID, title: "Paper", text: text).includingTimelineSource(document)
        model.snapshot.itemId = itemID
        model.snapshot.currentTextStart = 0
        let store = Gate1AppModel.pdfClipStore(support: try model.applicationSupportDirectory())
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 100)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        }
        try store.replaceClips(["t1": picture, "f1": picture], forItem: itemID, document: document)
        addTeardownBlock { try? store.removeClips(forItem: itemID) }

        NowClipCardCounter.reset()
        let controller = NowSceneController()
        let mounted = try mount(model, inScrollView: true, controller: controller)
        defer { mounted.close() }
        try await waitForAppearance(mounted)
        // Wait on the condition, with a deadline that is only a ceiling.
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline, Set(NowClipCardCounter.floatIds) != ["t1", "f1"] {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(Set(NowClipCardCounter.floatIds), ["t1", "f1"], "both pictures are drawn in the scene")
        let shape = (controller.state?.shownItems ?? []).map { item -> String in
            switch item {
            case .sentence(let sentence): sentence.text
            case .clip(let floatId, _): "card \(floatId)"
            case .margin(let item, _): "margin \(item.marginId)"
            }
        }
        let table = try XCTUnwrap(shape.firstIndex(of: "card t1"))
        let figure = try XCTUnwrap(shape.firstIndex(of: "card f1"))
        XCTAssertEqual(shape[table + 1], "Table 1.", "the table's card stands before the sentence that holds its caption")
        XCTAssertEqual(shape[figure + 1], "Figure 2.", "the figure's card stands before its caption's sentence")
        XCTAssertLessThan(table, figure, "cards stand in the order of the text")

        mounted.close()
        // An article has no document: the scene is its sentences and nothing else.
        let articleModel = makeModel(target: .itemTextTTS)
        NowClipCardCounter.reset()
        let articleController = NowSceneController()
        let article = try mount(articleModel, inScrollView: true, controller: articleController)
        defer { article.close() }
        try await waitForAppearance(article)
        let articleDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < articleDeadline, (articleController.state?.shownItems.count ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse((articleController.state?.shownItems ?? []).isEmpty, "the article's sentences are in the scene")
        XCTAssertTrue((articleController.state?.shownItems ?? []).allSatisfy { $0.sentence != nil }, "and no card among them")
        XCTAssertEqual(NowClipCardCounter.bodies, 0, "an article draws no card")
    }

    private func makeModel(target: TargetType, text: String? = nil) -> Gate1AppModel {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-view-\(UUID().uuidString).sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        // No bootstrap, source playback, or database reset: only the view's published inputs.
        model.selectedItem = ItemDetailState(id: "passage-view", title: "Article", text: text ?? self.text)
            .includingTimelineSource(nil)
        var snapshot = SessionSnapshot()
        snapshot.itemId = model.selectedItem.id
        snapshot.targetType = target.rawValue
        snapshot.status = .paused
        snapshot.currentTextStart = "First sentence. ".count
        model.snapshot = snapshot
        return model
    }

    private func mount(_ model: Gate1AppModel, inScrollView: Bool = false, controller suppliedController: NowSceneController? = nil) throws -> MountedPassage {
        // Made here, not as a default argument: a default argument is evaluated outside the main actor, and the
        // controller's initializer is main-actor isolated (the hosted app build failed on it).
        let controller = suppliedController ?? NowSceneController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let appeared = Appearance()
        // The one-point sibling proves the host appeared even when the passage has no children.
        let root = VStack(spacing: 0) {
            // As on the Now tab: the reader wraps the page scroll view, whose proxy the passage scrolls with.
            ScrollViewReader { proxy in
                let passage = PlaybackLivePassageView(scene: controller, proxy: proxy) { _ in XCTFail("Mounting must not open the reader") }
                if inScrollView {
                    // The passage in a page scroll view, which is what makes its rows lazy.
                    ScrollView { passage }.frame(height: 700)
                } else {
                    passage
                }
            }
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
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            if mounted.appeared.value { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The test's real SwiftUI host did not appear")
    }

    private func waitForHeight(_ mounted: MountedPassage, matching predicate: (CGFloat) -> Bool) async throws -> CGFloat {
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
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
