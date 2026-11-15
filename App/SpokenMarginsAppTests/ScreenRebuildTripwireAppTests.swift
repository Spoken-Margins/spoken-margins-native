import Combine
import SwiftUI
import UIKit
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4337: the tripwire sees a real rebuild. A tracked cover on a list row, the shape the Live row had in #4091, is
/// presented and the row is given a new identity again and again, which always tears it down and builds it again (list
/// churn alone does not re-host a row in a test harness; see `LiveSessionCoverRehostTests`). The cover goes and comes
/// back as a new screen each time, and the tripwire must count it. The same rebuilds with the cover presented from
/// outside the list must count nothing, so the tripwire does not cry wolf on an ordinary redraw.
@MainActor
final class ScreenRebuildTripwireAppTests: XCTestCase {
    private static let rowRebuilds = 8
    private var caught: [PresentationRebuildLedger.Rebuild] = []

    override func setUp() async throws {
        try await super.setUp()
        caught = []
        // This test rebuilds a screen on purpose: count rebuilds here instead of failing on them.
        ScreenRebuildTripwire.shared.onRebuild = { [weak self] in self?.caught.append($0) }
    }

    func testACoverOnAListRowRebuiltByTheListTripsTheTripwire() async throws {
        let churn = Churn()
        let mounted = try mount(AnyView(ChurnedList(churn: churn, coverOnRow: true)))
        defer { mounted.close() }
        try await waitForTheCover()
        try await churnTheList(churn)
        XCTAssertFalse(caught.isEmpty, "A cover on a list row was rebuilt with its row \(Self.rowRebuilds) times and the tripwire "
                           + "counted no rebuild; ledger summary: \(ScreenRebuildTripwire.shared.ledger.summary)")
        XCTAssertTrue(caught.allSatisfy { $0.presentation.hasPrefix("ScreenRebuildTripwireAppTests.swift:") },
                      "Rebuilds named another presentation: \(caught.map(\.presentation))")
    }

    func testTheSameCoverPresentedFromOutsideTheListTripsNothing() async throws {
        let churn = Churn()
        let mounted = try mount(AnyView(ChurnedList(churn: churn, coverOnRow: false)))
        defer { mounted.close() }
        try await waitForTheCover()
        try await churnTheList(churn)
        XCTAssertTrue(caught.isEmpty, "A cover outside the list was counted as rebuilt: \(caught.map(\.presentation))")
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
                ForEach(0..<12, id: \.self) { Text("Item \($0)") }
            }
        }
    }

    private struct Cover: View {
        var body: some View { Text("Cover").accessibilityIdentifier("tripwire.cover") }
    }

    private func churnTheList(_ churn: Churn) async throws {
        for _ in 0..<Self.rowRebuilds {
            churn.rowGeneration += 1
            try await Task.sleep(for: .milliseconds(700))
        }
        try await Task.sleep(for: .milliseconds(500))
    }

    private func waitForTheCover() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if ScreenRebuildTripwire.shared.ledger.summary == "none", presentedCount() > 0 { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("The cover never presented")
    }

    private var mountedWindow: UIWindow?

    private func presentedCount() -> Int {
        mountedWindow?.rootViewController?.presentedViewController == nil ? 0 : 1
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
        mountedWindow = window
        return Mounted(window: window, previousKeyWindow: previousKeyWindow)
    }
}
