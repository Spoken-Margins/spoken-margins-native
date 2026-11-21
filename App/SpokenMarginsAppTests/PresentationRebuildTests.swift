import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #4337: a cover that is dismissed and presented again by itself is a screen built twice, and it must trip.
///
/// The cover is mounted for real, in a window of the test app, and presented the way the app presents one, through
/// `trackedFullScreenCover`. The control presents it again after the window has passed and must not trip, so a pass
/// of the first test can't be a tripwire that fires on every second presentation.
@MainActor
final class PresentationRebuildTests: XCTestCase {
    private final class CoverSwitch: ObservableObject {
        @Published var isOn = false
        var appeared = 0
        var disappeared = 0
    }

    private struct Host: View {
        @ObservedObject var model: CoverSwitch

        var body: some View {
            Color.clear.trackedFullScreenCover(isPresented: Binding(get: { model.isOn }, set: { model.isOn = $0 })) {
                Text("Cover")
                    .onAppear { model.appeared += 1 }
                    .onDisappear { model.disappeared += 1 }
            }
        }
    }

    private var captured: [PresentationLedger.Rebuild] = []

    override func setUp() async throws {
        try await super.setUp()
        // These tests rebuild a cover on purpose, so they catch the rebuilds themselves instead of failing on them.
        PresentationTracker.shared.onRebuild = { [weak self] rebuild in
            Task { @MainActor in self?.captured.append(rebuild) }
        }
    }

    override func tearDown() async throws {
        PresentationRebuildGuard.shared?.attach()
        try await super.tearDown()
    }

    func testACoverDismissedAndPresentedAgainWithinASecondTripsTheTripwire() async throws {
        let model = CoverSwitch()
        let window = try mount(model)
        defer { window.close() }

        model.isOn = true
        try await wait("the cover to appear") { model.appeared == 1 }
        model.isOn = false
        try await wait("the cover to go") { model.disappeared == 1 }
        model.isOn = true
        try await wait("the cover to appear again") { model.appeared == 2 }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(captured.map(\.reason), [.afterDismissal], "a second build within a second of the first going is a rebuild")
        XCTAssertTrue(captured.first?.place.hasPrefix("PresentationRebuildTests:") == true, "it names the presentation: \(captured.first?.place ?? "none")")
        XCTAssertTrue(PresentationTracker.shared.summary.hasPrefix("rebuilds=1 "), PresentationTracker.shared.summary)
    }

    func testTheSameCoverPresentedAgainAfterTheWindowIsTheListenerOpeningItAgain() async throws {
        let model = CoverSwitch()
        let window = try mount(model)
        defer { window.close() }

        model.isOn = true
        try await wait("the cover to appear") { model.appeared == 1 }
        model.isOn = false
        try await wait("the cover to go") { model.disappeared == 1 }
        try await Task.sleep(for: .seconds(PresentationLedger.rebuildWindow + 0.3))
        model.isOn = true
        try await wait("the cover to appear again") { model.appeared == 2 }
        // The tracker is told of an appearance by a modifier around the cover's content, so it can run after the cover's
        // own `onAppear`, and a rebuild reaches `captured` by one more hop. A cover can only go after it has appeared and
        // been reported, so its second disappearance marks the point after which a rebuild would have been captured.
        model.isOn = false
        try await wait("the cover to go again") { model.disappeared == 2 }
        await Task.yield()

        XCTAssertEqual(captured, [], "a cover the listener opens again after a pause is not a rebuild")
        XCTAssertEqual(PresentationTracker.shared.summary, "rebuilds=0")
    }

    func testARebuildFailsTheRunningTest() {
        XCTExpectFailure("PresentationRebuildGuard records an issue on the running test when a screen is built twice") {
            PresentationRebuildGuard.shared?.attach() // setUp swapped in the catching handler
            PresentationTracker.shared.appeared(place: "Probe:1", item: nil, instance: UUID())
            PresentationTracker.shared.appeared(place: "Probe:1", item: nil, instance: UUID())
        }
    }

    func testTheGuardIsInstalledByTheBundle() {
        XCTAssertNotNil(PresentationRebuildGuard.shared, "OpenDescriptorGuard.init must call PresentationRebuildGuard.install()")
    }

    // MARK: - Mounting

    private struct Mounted {
        let window: UIWindow
        let previousKeyWindow: UIWindow?

        @MainActor func close() {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
    }

    private func mount(_ model: CoverSwitch) throws -> Mounted {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: Host(model: model))
        window.makeKeyAndVisible()
        return Mounted(window: window, previousKeyWindow: previousKeyWindow)
    }

    private func wait(_ what: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
