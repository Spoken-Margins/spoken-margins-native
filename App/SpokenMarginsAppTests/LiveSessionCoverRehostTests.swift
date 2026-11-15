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
/// The Live row presented the screen from a cover on a Library list row. These tests mount the real Live row in a real
/// `List`, open the session by activating the row's button, then churn the list the way the Library changes while it
/// sits under the screen (rows above come and go, items are added and removed, the model publishes) and count how many
/// screens were built. The control runs the same churn against a cover hosted on a list row, the shape the Live row
/// had; if it shows no rebuilds, this churn no longer re-hosts a row and the first test's pass proves nothing.
@MainActor
final class LiveSessionCoverRehostTests: XCTestCase {
    private static let churnSteps = 40
    private static let sessionId = "live-rehost-4091-not-stored"

    override func tearDown() async throws {
        LiveSessionLinkRouter.shared.cover = nil
        try await super.tearDown()
    }

    func testTheLiveRowsScreenIsBuiltOnceWhileTheLibraryListChanges() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let churn = ListChurn()
        let board = LiveSessionBoard(rows: [Self.runningRow()])
        let built = ScreenRedrawProbe.count("liveSessionController.init")
        let mounted = try mount(AnyView(LibraryLikeList(churn: churn, model: model) { LiveSessionLiveRows(board: board) }
            .liveSessionLinkCover(model)
            .environmentObject(model)))
        defer { mounted.close() }

        let how = try await openFromTheLiveRow(in: mounted)
        try await waitUntil("the live session screen was built") { ScreenRedrawProbe.count("liveSessionController.init") > built }
        try await churnTheList(churn, model: model)

        let builds = ScreenRedrawProbe.count("liveSessionController.init") - built
        XCTAssertEqual(builds, 1, "Opened by \(how), the live session screen was built \(builds) times while the list changed "
                           + "\(Self.churnSteps) times: each extra build is the setup card flashing and any open sheet closing")
        var visited = Set<ObjectIdentifier>()
        XCTAssertNotNil(Self.accessibilityElement(withIdentifier: "liveSession.back.button", in: mounted.window, visited: &visited),
                        "The live session screen was not up after the list changed")
    }

    func testControlACoverHostedOnAListRowIsBuiltAgainByTheSameChurn() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let churn = ListChurn()
        let built = ScreenRedrawProbe.count("rehostControl.build")
        let mounted = try mount(AnyView(LibraryLikeList(churn: churn, model: model) { RowHostedCover() }.environmentObject(model)))
        defer { mounted.close() }

        try await waitUntil("the control's cover was built") { ScreenRedrawProbe.count("rehostControl.build") > built }
        try await churnTheList(churn, model: model)

        let builds = ScreenRedrawProbe.count("rehostControl.build") - built
        XCTAssertGreaterThan(builds, 1, "A cover on a list row was built \(builds) time(s) across \(Self.churnSteps) list changes, so "
                                 + "this churn no longer re-hosts a row and the Live row test guards nothing")
    }

    // MARK: - Churn

    /// What changes under the screen while it is up: a row above the Live row comes and goes (the copied-link card),
    /// items are added and removed (a link finishing, an item completed), and the model publishes (audio rendering).
    private func churnTheList(_ churn: ListChurn, model: Gate1AppModel) async throws {
        for step in 0..<Self.churnSteps {
            switch step % 4 {
            case 0: churn.showsCardAbove.toggle()
            case 1: churn.items.insert("Item \(1_000 + step)", at: 0)
            case 2: churn.items.removeLast()
            default: model.objectWillChange.send()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(500)) // a presentation dismissed by the last change has time to come back
    }

    // MARK: - Opening

    /// Opens the session the way a tap does: through the Live row button's accessibility activation. Says how it opened.
    private func openFromTheLiveRow(in mounted: Mounted) async throws -> String {
        let identifier = "library.liveRow.\(Self.sessionId)"
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            var visited = Set<ObjectIdentifier>()
            if let button = Self.accessibilityElement(withIdentifier: identifier, in: mounted.window, visited: &visited) {
                XCTAssertTrue(button.accessibilityActivate(), "The Live row's button refused activation")
                return "the Live row button"
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The Live row's button never appeared")
        throw Unsettled()
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
        @Published var showsCardAbove = false
        @Published var items = (0..<12).map { "Item \($0)" }
    }

    /// The Library's shape: a `List` that watches the model, a row above the Live row that comes and goes, the Live row,
    /// then the items.
    private struct LibraryLikeList<LiveRow: View>: View {
        @ObservedObject var churn: ListChurn
        @ObservedObject var model: Gate1AppModel
        @ViewBuilder var liveRow: () -> LiveRow

        var body: some View {
            List {
                if churn.showsCardAbove { Text("A copied link") }
                liveRow()
                ForEach(churn.items, id: \.self) { Text($0) }
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

    /// The first element at or under `root` whose accessibility identifier is `identifier`, looking through views and
    /// accessibility containers the way a UI test does.
    private static func accessibilityElement(withIdentifier identifier: String, in root: NSObject, visited: inout Set<ObjectIdentifier>) -> NSObject? {
        guard visited.insert(ObjectIdentifier(root)).inserted else { return nil }
        if (root as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier { return root }
        var children: [NSObject] = []
        if let view = root as? UIView {
            children += (view.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            children += view.subviews
        }
        let count = root.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            children += (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        for child in children {
            if let found = accessibilityElement(withIdentifier: identifier, in: child, visited: &visited) { return found }
        }
        return nil
    }
}
