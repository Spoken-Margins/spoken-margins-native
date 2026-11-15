import Combine
import SwiftUI
import UIKit
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4091, seen on the owner's phone on build 37 (df6a828), which already had the redraw fix: a running live session
/// could not be ended. Every few seconds the screen was built again: the setup card flashed for a frame and the End
/// Session sheet closed before it could be answered. The setup card only shows on a screen that has not loaded its
/// session yet, so the screen was being created anew, not redrawn.
///
/// The Live row presented the screen from a cover on a Library list row, so whenever the Library re-hosted that row
/// the cover went with it and came back as a new screen. Ordinary list churn in a test harness does not make SwiftUI
/// re-host a row (the desk tried: 40 changes, one build), so these tests force the strongest form of it: the row gets
/// a new identity, which always tears it down and builds it again. The Live row test opens the session the way the
/// row's button does, through `LiveSessionLinkRouter` with the window the row is in, then rebuilds the row over and
/// over and counts screens built. The test host's own root is a second window on the same router, so a screen counted
/// twice is also a Live row opening its screen in every window (an iPad with two windows), not just in its own.
/// The control does the same to a cover hosted on the row, the shape the Live row had; if it is not built again, the
/// rebuild no longer reaches the row and the Live row test proves nothing.
///
/// What this does not cover: whether the row's button still calls the router (the harness could not find the button
/// in the accessibility tree), and what the real Library does to re-host a row. The fix was checked on a simulator
/// against a no-fix control for that (#4091).
@MainActor
final class LiveSessionCoverRehostTests: XCTestCase {
    private static let rowRebuilds = 8
    private static let sessionId = "live-rehost-4091-not-stored"

    override func tearDown() async throws {
        LiveSessionLinkRouter.shared.cover = nil
        try await super.tearDown()
    }

    func testTheLiveRowsScreenIsBuiltOnceWhileTheLibraryListChanges() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let churn = ListChurn()
        let board = LiveSessionBoard(rows: [Self.runningRow()])
        let rowsWindow = LiveSessionWindowProbe.Seen()
        let built = ScreenRedrawProbe.count("liveSessionController.init")
        let mounted = try mount(AnyView(LibraryLikeList(churn: churn, model: model) {
            LiveSessionLiveRows(board: board).background { LiveSessionWindowProbe(seen: rowsWindow) }
        }
            .liveSessionLinkCover(model)
            .environmentObject(model)))
        defer { mounted.close() }

        try await waitUntil("the Live row knew its window") { rowsWindow.window != nil }
        LiveSessionLinkRouter.shared.openScreen(sessionId: Self.sessionId, window: rowsWindow.window)
        try await waitUntil("the live session screen was built") { ScreenRedrawProbe.count("liveSessionController.init") > built }
        try await rebuildTheRow(churn, model: model)

        let builds = ScreenRedrawProbe.count("liveSessionController.init") - built
        XCTAssertEqual(builds, 1, "The live session screen was built \(builds) times while the Live row was rebuilt "
                           + "\(Self.rowRebuilds) times: each extra build is the setup card flashing and any open sheet closing")
        // Dismissing the screen clears the router's cover through the binding, so a cover still set and still presented
        // in this window is the screen still up. (An accessibility lookup read no identifiers here: a unit test does not
        // turn accessibility automation on, and SwiftUI's elements don't answer the protocol cast.)
        XCTAssertEqual(LiveSessionLinkRouter.shared.cover?.sessionId, Self.sessionId, "The live session screen was closed while the list changed")
        XCTAssertNotNil(mounted.window.rootViewController?.presentedViewController,
                        "The live session screen was not presented in the Live row's window after the list changed")
    }

    func testControlACoverHostedOnAListRowIsBuiltAgainByTheSameChurn() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let churn = ListChurn()
        let built = ScreenRedrawProbe.count("rehostControl.build")
        let mounted = try mount(AnyView(LibraryLikeList(churn: churn, model: model) { RowHostedCover() }.environmentObject(model)))
        defer { mounted.close() }

        try await waitUntil("the control's cover was built") { ScreenRedrawProbe.count("rehostControl.build") > built }
        try await rebuildTheRow(churn, model: model)

        let builds = ScreenRedrawProbe.count("rehostControl.build") - built
        XCTAssertGreaterThan(builds, 1, "A cover on a list row was built \(builds) time(s) across \(Self.rowRebuilds) row rebuilds, so "
                                 + "the rebuild no longer reaches the row and the Live row test guards nothing")
    }

    // MARK: - Rebuilding the row

    /// Gives the row a new identity, so SwiftUI tears it down and builds it again, with the model publishing in between
    /// the way it does while audio renders. The pause lets a cover dismissed with the old row present again.
    private func rebuildTheRow(_ churn: ListChurn, model: Gate1AppModel) async throws {
        // fixed-count ok: it makes `rowRebuilds` row rebuilds, one per pass, and waits for no condition; the pause is a settle, not a deadline
        for _ in 0..<Self.rowRebuilds {
            churn.rowGeneration += 1
            model.objectWillChange.send()
            try await Task.sleep(for: .milliseconds(700))
        }
        try await Task.sleep(for: .milliseconds(500))
    }

    private static func runningRow() -> LiveSessionFileWorker.Summary {
        let now = Date()
        return LiveSessionFileWorker.Summary(
            id: sessionId, title: "Meeting", kind: .meeting, isQuick: false, isRunning: true,
            startedAt: now.addingTimeInterval(-600), endedAt: nil, marginCount: 5, resumableUntil: nil)
    }

    // MARK: - Fixtures

    @MainActor
    private final class ListChurn: ObservableObject {
        @Published var rowGeneration = 0
    }

    /// The Library's shape: a `List` that watches the model, the Live row (rebuilt whenever `rowGeneration` moves), then
    /// items.
    private struct LibraryLikeList<LiveRow: View>: View {
        @ObservedObject var churn: ListChurn
        @ObservedObject var model: Gate1AppModel
        @ViewBuilder var liveRow: () -> LiveRow

        var body: some View {
            List {
                liveRow().id(churn.rowGeneration)
                ForEach(0..<12, id: \.self) { Text("Item \($0)") }
                Text(model.shouldShowMiniPlayer ? "Mini player" : "No mini player")
            }
        }
    }

    /// The control: the shape the Live row had, a cover presented from a view inside a list row.
    private struct RowHostedCover: View {
        @State private var isPresented = true

        var body: some View {
            Text("Live · Meeting")
                .background { Color.clear.fullScreenCover(isPresented: $isPresented) { ControlScreen() } }
        }
    }

    private struct ControlScreen: View {
        @StateObject private var token = BuildToken()

        var body: some View { Text("Control screen") }
    }

    @MainActor
    private final class BuildToken: ObservableObject {
        init() { ScreenRedrawProbe.record("rehostControl.build") }
    }

    // MARK: - Mounting

    private struct Unsettled: Error {}

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

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Timed out waiting until \(what)")
        throw Unsettled()
    }
}

/// Reads the window a view is in, the way the Live row's button does, so a test can open the screen from where the
/// row is (#4091).
struct LiveSessionWindowProbe: View {
    @MainActor
    final class Seen {
        var window: UUID?
    }

    let seen: Seen
    @Environment(\.liveSessionWindow) private var window

    var body: some View {
        Color.clear.onAppear { seen.window = window }
    }
}
