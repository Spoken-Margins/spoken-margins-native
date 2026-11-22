import Combine
import SwiftUI
import UIKit
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4091: with an item in the mini player, the live session screen flashed and Discard Session could not be tapped.
/// The likely cause, read from the code and not yet reproduced on a device: the screen watched the whole
/// `Gate1AppModel`, and the Live row presented it from a Library row that redraws on every model publish, so each
/// publish reran the whole screen, the class that once closed this screen's menus and sheets (#2831). The screen now
/// reads the model through a feed, and the Live row has the root present it (`LiveSessionLinkRouter.openScreen`).
///
/// The screen is presented the way the Live row presents it, from a presenter that watches the model (as the Library
/// does), left to settle, then given 20 model publishes 25 ms apart. The control runs the same publishes against a
/// screen that watches the model, as the live session screen did before the fix, and must show the redraws; if it
/// doesn't, these publishes no longer reach a watching screen and the first test's pass proves nothing.
@MainActor
final class LiveSessionRedrawTests: XCTestCase {
    private static let publishes = 20
    /// A stray draw from the screen's own late first-appearance work is not a publish redrawing it.
    private static let allowedRuns = 3
    /// A session id the store doesn't hold: the screen opens on its setup card and writes nothing to the store.
    private static let sessionId = "live-redraw-4091-not-stored"
    /// How many 40 ms polls the screen's body-run count must stay still before the publishes are counted. 1 s, not 0.4 s:
    /// the first attempt of this test in a fresh process failed with 13 body runs and passed on its retry (#4379), and
    /// that attempt took 6.0 s against 2.4 s, so the screen's cold-start work comes in bursts with gaps longer than 0.4 s.
    private static let quietPolls = 25

    func testTheLiveSessionScreenIsNotRedrawnByModelPublishes() async throws {
        let model = try makeModel()
        let modelPublishes = PublishCounter(model)
        let presented = ScreenRedrawProbe.count("liveSession")
        let presentersWindow = LiveSessionWindowProbe.Seen()
        let mounted = try mount(AnyView(LiveRowLikePresenter(model: model, seen: presentersWindow)))
        defer {
            LiveSessionLinkRouter.shared.cover = nil
            mounted.close()
        }
        try await waitForWindow(presentersWindow)
        LiveSessionLinkRouter.shared.openScreen(sessionId: Self.sessionId, window: presentersWindow.window)
        try await waitForFirstRun("liveSession", after: presented)
        try await waitUntilQuiet("liveSession")
        let screenBefore = ScreenRedrawProbe.count("liveSession")
        let checksBefore = ScreenRedrawProbe.equalityCheckCount("liveSession")
        let modelBefore = modelPublishes.count
        let sourcesBefore = ScreenRedrawProbe.publishes
        // From here the screen's body prints SwiftUI's reason for each run, so a failing attempt's log says what changed (#4379).
        ScreenRedrawProbe.printsChanges.insert("liveSession")
        defer { ScreenRedrawProbe.printsChanges.remove("liveSession") }

        let runsAtEachPublish = try await publish(on: model, watching: "liveSession")

        try await waitUntilQuiet("liveSession")
        let sources = Self.publishesSince(sourcesBefore)
        let screenRuns = ScreenRedrawProbe.count("liveSession") - screenBefore
        let checks = ScreenRedrawProbe.equalityCheckCount("liveSession") - checksBefore
        // The runs so far after each publish, so a failure says whether the runs follow the publishes (a redraw by each one)
        // or arrive in a burst of their own (the screen's late work), which the first failure in #4379 could not say.
        XCTAssertLessThanOrEqual(screenRuns, Self.allowedRuns,
                                 "\(Self.publishes) model publishes ran the live session screen's body \(screenRuns) times "
                                     + "(SwiftUI asked the screen's == \(checks) times; the model published "
                                     + "\(modelPublishes.count - modelBefore) times; runs after each publish: "
                                     + "\(runsAtEachPublish.map { $0 - screenBefore }); announcements by the screen's own objects: "
                                     + "\(sources.isEmpty ? "none" : sources))")
    }

    func testControlAScreenThatWatchesTheModelIsRedrawnByTheSamePublishes() async throws {
        let model = try makeModel()
        let presented = ScreenRedrawProbe.count("liveSessionControl")
        let mounted = try mount(AnyView(WatchingCoverPresenter(model: model)))
        defer { mounted.close() }
        try await waitForFirstRun("liveSessionControl", after: presented)
        try await waitUntilQuiet("liveSessionControl")
        let before = ScreenRedrawProbe.count("liveSessionControl")

        _ = try await publish(on: model, watching: "liveSessionControl")

        try await waitUntilQuiet("liveSessionControl")
        let runs = ScreenRedrawProbe.count("liveSessionControl") - before
        XCTAssertGreaterThan(runs, Self.allowedRuns,
                             "A screen watching the model ran \(runs) times for \(Self.publishes) publishes, so these publishes "
                                 + "no longer show the redraw the live session screen test guards")
    }

    // MARK: - Publishing

    /// The screen's own objects that announced a change since `before`, as "controller 20, feed 0" (#4379).
    /// The failing attempt of 2026-11-19 showed one body run for each publish with the screen's `==` never asked, so the
    /// redraw came from inside the screen, not from the presenter; this names which of its objects asked for it. The
    /// controller forwards the capture's announcements, so a capture count is also counted under "controller".
    private static func publishesSince(_ before: [String: Int]) -> String {
        ScreenRedrawProbe.publishes
            .map { (name: $0.key, count: $0.value - before[$0.key, default: 0]) }
            .filter { $0.name.hasPrefix("liveSession.") && $0.count > 0 }
            .sorted { $0.name < $1.name }
            .map { "\($0.name.dropFirst("liveSession.".count)) \($0.count)" }
            .joined(separator: ", ")
    }

    /// What the model sends while an item renders and plays: bare publishes and a new rendered-chunk count.
    /// Returns the screen's body-run count after each publish.
    private func publish(on model: Gate1AppModel, watching screen: String) async throws -> [Int] {
        var runsAfterEach: [Int] = []
        for index in 0..<Self.publishes {
            if index.isMultiple(of: 2) {
                model.objectWillChange.send()
            } else {
                model.updateOnDeviceSpeechGenerationProgress(RenderedSpeechGenerationProgress(completedChunks: 100 + index, totalChunks: 959))
            }
            try await Task.sleep(for: .milliseconds(25))
            runsAfterEach.append(ScreenRedrawProbe.count(screen))
        }
        return runsAfterEach
    }

    // MARK: - Fixtures

    /// Counts the model's own publishes, for the failure message: the seeded model starts work of its own that could change
    /// what the screen shows (its mini player) while the test is counting, and a count says whether it did.
    @MainActor
    private final class PublishCounter {
        private(set) var count = 0
        private var subscription: AnyCancellable?

        init(_ model: Gate1AppModel) {
            subscription = model.objectWillChange.sink { [weak self] _ in self?.count += 1 }
        }
    }

    private func makeModel() throws -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        return model
    }

    /// The Library's shape around the Live row: a presenter that watches the model, so every publish redraws it, with
    /// the root's live session cover, which is where the Live row's screen is presented from.
    private struct LiveRowLikePresenter: View {
        @ObservedObject var model: Gate1AppModel
        let seen: LiveSessionWindowProbe.Seen

        var body: some View {
            Color.clear.background { LiveSessionWindowProbe(seen: seen) }.liveSessionLinkCover(model)
        }
    }

    /// The control: a plain cover on the watching presenter, holding a screen that watches the model itself.
    private struct WatchingCoverPresenter: View {
        @ObservedObject var model: Gate1AppModel
        @State private var isPresented = true

        var body: some View {
            Color.clear
                .fullScreenCover(isPresented: $isPresented) { WatchingScreen().environmentObject(model) }
        }
    }

    private struct WatchingScreen: View {
        @EnvironmentObject private var model: Gate1AppModel

        var body: some View {
            let _ = ScreenRedrawProbe.record("liveSessionControl")
            Text(model.shouldShowMiniPlayer ? "Mini player" : "No mini player")
        }
    }

    // MARK: - Mounting

    @MainActor
    private struct Mounted {
        let window: UIWindow
        let previousKeyWindow: UIWindow?

        func close() {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
    }

    private func mount(_ view: AnyView) throws -> Mounted {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return Mounted(window: window, previousKeyWindow: previousKeyWindow)
    }

    /// The presenter has appeared and read its window, so the screen opens in this test's window only, not also in the
    /// test host's (#4091).
    private func waitForWindow(_ seen: LiveSessionWindowProbe.Seen) async throws {
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            if seen.window != nil { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("The presenter never read its window")
    }

    /// The cover has presented once the screen's body has run since `count` was read, before mounting.
    private func waitForFirstRun(_ screen: String, after count: Int) async throws {
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            if ScreenRedrawProbe.count(screen) > count { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("\(screen) was never presented")
    }

    /// Returns once the screen's body-run count has not moved for `quietPolls` polls (1 s): the screen's own first-appearance
    /// work is over, so what is counted next is the publishes. The model's publishes are not part of this wait: if the seeded
    /// model ever publishes on a timer, waiting for it to go quiet would fail the test for good.
    private func waitUntilQuiet(_ screen: String) async throws {
        var last = ScreenRedrawProbe.count(screen)
        var quiet = 0
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            try await Task.sleep(for: .milliseconds(40))
            let now = ScreenRedrawProbe.count(screen)
            quiet = now == last ? quiet + 1 : 0
            last = now
            if quiet >= Self.quietPolls { return }
        }
        XCTFail("\(screen) kept redrawing with nothing changing (\(last) body runs)")
    }
}
