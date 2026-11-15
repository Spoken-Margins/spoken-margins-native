import Combine
import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #4337: the tracker sees a rebuild the way #4091 made one. A tracked cover on a list row is presented and the row
/// is given a new identity again and again, which always tears it down and builds it again (list churn alone does not
/// re-host a row in a test harness; see `LiveSessionCoverRehostTests`). The cover goes and comes back as a new screen
/// each time, and the tracker must count it. The same churn with the cover presented from outside the list must count
/// nothing, so the tracker does not cry wolf on an ordinary redraw. `PresentationRebuildTests` covers the rule on a
/// cover that is dismissed and presented again by hand; this covers the shape that reached the owner's phone.
@MainActor
final class PresentationRebuildListRowTests: XCTestCase {
    private static let rowRebuilds = 8
    private var caught: [PresentationLedger.Rebuild] = []

    override func setUp() async throws {
        try await super.setUp()
        caught = []
        // These tests rebuild a screen on purpose, so they catch the rebuilds themselves instead of failing on them.
        PresentationTracker.shared.onRebuild = { [weak self] rebuild in
            Task { @MainActor in self?.caught.append(rebuild) }
        }
    }

    override func tearDown() async throws {
        PresentationRebuildGuard.shared?.attach()
        try await super.tearDown()
    }

    func testACoverOnAListRowRebuiltByTheListTripsTheTracker() async throws {
        let churn = Churn()
        let mounted = try mount(AnyView(ChurnedList(churn: churn, coverOnRow: true)))
        defer { mounted.close() }
        try await waitForTheCover()
        try await churnTheList(churn)

        XCTAssertFalse(caught.isEmpty, "A cover on a list row was rebuilt with its row \(Self.rowRebuilds) times and the tracker "
                       + "counted no rebuild; summary: \(PresentationTracker.shared.summary)")
        XCTAssertTrue(caught.allSatisfy { $0.place.hasPrefix("PresentationRebuildListRowTests:") },
                      "Rebuilds named another presentation: \(caught.map(\.place))")
        XCTAssertTrue(PresentationTracker.shared.summary.hasPrefix("rebuilds="), PresentationTracker.shared.summary)
        XCTAssertNotEqual(PresentationTracker.shared.summary, "rebuilds=0", "the Diagnostics line says what the test saw")
    }

    func testTheSameCoverPresentedFromOutsideTheListTripsNothing() async throws {
        let churn = Churn()
        let mounted = try mount(AnyView(ChurnedList(churn: churn, coverOnRow: false)))
        defer { mounted.close() }
        try await waitForTheCover()
        try await churnTheList(churn)

        XCTAssertTrue(caught.isEmpty, "A cover outside the list was counted as rebuilt: \(caught.map(\.place))")
        XCTAssertEqual(PresentationTracker.shared.summary, "rebuilds=0")
    }

    // MARK: - Fixtures

    @MainActor
    private final class Churn: ObservableObject {
        @Published var rowGeneration = 0
    }

    private struct ChurnedList: View {
        @ObservedObject var churn: Churn
        let coverOnRow: Bool
        @State private var isPresented = true

        var body: some View {
            if coverOnRow {
                list(row: Text("Live · Meeting").background { Color.clear.trackedFullScreenCover(isPresented: $isPresented) { Cover() } })
            } else {
                list(row: Text("Live · Meeting")).trackedFullScreenCover(isPresented: $isPresented) { Cover() }
            }
        }

        private func list(row: some View) -> some View {
            List {
                row.id(churn.rowGeneration)
                ForEach(0..<12, id: \.self) { Text("Row \($0)") }
            }
        }
    }

    private struct Cover: View {
        var body: some View { Text("Cover").accessibilityIdentifier("tracker.cover") }
    }

    private func churnTheList(_ churn: Churn) async throws {
        // fixed-count ok: it makes `rowRebuilds` list rebuilds, one per pass, and waits for nothing
        for _ in 0..<Self.rowRebuilds {
            churn.rowGeneration += 1
            try await Task.sleep(for: .milliseconds(700))
        }
        try await Task.sleep(for: .milliseconds(500))
    }

    private func waitForTheCover() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if mountedWindow?.rootViewController?.presentedViewController != nil { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("The cover never presented")
    }

    // MARK: - Mounting

    private var mountedWindow: UIWindow?

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
        mountedWindow = window
        return Mounted(window: window, previousKeyWindow: previousKeyWindow)
    }
}
