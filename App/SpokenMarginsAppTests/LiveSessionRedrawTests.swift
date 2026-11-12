import SwiftUI
import UIKit
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4091: with an item in the mini player, the live session screen flashed and Discard Session could not be tapped.
/// The likely cause, read from the code and not yet reproduced on a device: the screen watched the whole
/// `Gate1AppModel`, and the Live row presented it from a Library row that redraws on every model publish, so each
/// publish reran the whole screen, the class that once closed this screen's menus and sheets (#2831). The screen now
/// reads the model through a feed, and the Live row presents it from `LiveSessionCoverHost`.
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

    func testTheLiveSessionScreenIsNotRedrawnByModelPublishes() async throws {
        let model = try makeModel()
        let presented = ScreenRedrawProbe.count("liveSession")
        let mounted = try mount(AnyView(LiveRowLikePresenter(model: model, sessionId: Self.sessionId)))
        defer { mounted.close() }
        try await waitForFirstRun("liveSession", after: presented)
        try await waitUntilQuiet("liveSession")
        let screenBefore = ScreenRedrawProbe.count("liveSession")
        let hostBefore = ScreenRedrawProbe.count("liveSessionCoverHost")
        let checksBefore = ScreenRedrawProbe.equalityCheckCount("liveSession")

        try await publish(on: model)

        try await waitUntilQuiet("liveSession")
        let screenRuns = ScreenRedrawProbe.count("liveSession") - screenBefore
        let hostRuns = ScreenRedrawProbe.count("liveSessionCoverHost") - hostBefore
        let checks = ScreenRedrawProbe.equalityCheckCount("liveSession") - checksBefore
        XCTAssertLessThanOrEqual(screenRuns, Self.allowedRuns,
                                 "\(Self.publishes) model publishes ran the live session screen's body \(screenRuns) times "
                                     + "(its cover host \(hostRuns) times; SwiftUI asked the screen's == \(checks) times)")
        XCTAssertLessThanOrEqual(hostRuns, Self.allowedRuns,
                                 "\(Self.publishes) model publishes re-ran the Live row's cover host \(hostRuns) times")
    }

    func testControlAScreenThatWatchesTheModelIsRedrawnByTheSamePublishes() async throws {
        let model = try makeModel()
        let presented = ScreenRedrawProbe.count("liveSessionControl")
        let mounted = try mount(AnyView(WatchingCoverPresenter(model: model)))
        defer { mounted.close() }
        try await waitForFirstRun("liveSessionControl", after: presented)
        try await waitUntilQuiet("liveSessionControl")
        let before = ScreenRedrawProbe.count("liveSessionControl")

        try await publish(on: model)

        try await waitUntilQuiet("liveSessionControl")
        let runs = ScreenRedrawProbe.count("liveSessionControl") - before
        XCTAssertGreaterThan(runs, Self.allowedRuns,
                             "A screen watching the model ran \(runs) times for \(Self.publishes) publishes, so these publishes "
                                 + "no longer show the redraw the live session screen test guards")
    }

    // MARK: - Publishing

    /// What the model sends while an item renders and plays: bare publishes and a new rendered-chunk count.
    private func publish(on model: Gate1AppModel) async throws {
        for index in 0..<Self.publishes {
            if index.isMultiple(of: 2) {
                model.objectWillChange.send()
            } else {
                model.updateOnDeviceSpeechGenerationProgress(RenderedSpeechGenerationProgress(completedChunks: 100 + index, totalChunks: 959))
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - Fixtures

    private func makeModel() throws -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        return model
    }

    /// The Library's shape around the Live row: a presenter that watches the model, so every publish redraws it, and
    /// presents the live session screen the way the Live row does.
    private struct LiveRowLikePresenter: View {
        @ObservedObject var model: Gate1AppModel
        @State var sessionId: String?

        var body: some View {
            Color.clear
                .background { LiveSessionCoverHost(model: model, sessionId: $sessionId).equatable() }
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

    /// The cover has presented once the screen's body has run since `count` was read, before mounting.
    private func waitForFirstRun(_ screen: String, after count: Int) async throws {
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            if ScreenRedrawProbe.count(screen) > count { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("\(screen) was never presented")
    }

    /// The body-run count once it has not moved for 10 polls (0.4 s): the screen's own first-appearance work is over, so
    /// what is counted next is the publishes.
    private func waitUntilQuiet(_ screen: String) async throws {
        var last = ScreenRedrawProbe.count(screen)
        var quiet = 0
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            try await Task.sleep(for: .milliseconds(40))
            let now = ScreenRedrawProbe.count(screen)
            quiet = now == last ? quiet + 1 : 0
            last = now
            if quiet >= 10 { return }
        }
        XCTFail("\(screen) kept redrawing with nothing changing (\(last) body runs)")
    }
}
