import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Mounts the live session's running layout (the Margins pane over its dock) with 50 Margins and measures where the
/// dock lands in a short phone's window. The old screen put End Session at the bottom of one long scroll, so a
/// long session buried it; now the dock sits in the bottom safe area and the Margins scroll above it (#3491). UIKit
/// probes give window coordinates, as in `MiniPlayerKeepOutLayoutTests`.
@MainActor
final class LiveSessionDockLayoutAppTests: XCTestCase {
    func testTheDockStaysInsideTheSafeAreaOver50Margins() async throws {
        let mounted = try mount(marginCount: 50, size: CGSize(width: 375, height: 667))
        defer { mounted.close() }
        let frames = try await settledFrames(in: mounted, names: ["dock", "pane"])
        let dock = frames["dock"]!, pane = frames["pane"]!
        let safeBottom = mounted.window.bounds.height - mounted.window.safeAreaInsets.bottom

        XCTAssertLessThanOrEqual(dock.maxY, safeBottom + 0.5, "The dock (with End) ends at \(dock.maxY), below the safe area at \(safeBottom)")
        XCTAssertGreaterThanOrEqual(dock.minY, mounted.window.bounds.height / 2, "The dock takes more than half of a short phone: \(dock)")
        XCTAssertLessThanOrEqual(pane.maxY, dock.minY + 0.5, "The Margins pane runs under the dock")
    }

    func testTheDockIsTheSameHeightWithNoMargins() async throws {
        let many = try mount(marginCount: 50, size: CGSize(width: 375, height: 667))
        let manyDock = try await settledFrames(in: many, names: ["dock"])["dock"]!
        many.close()
        let none = try mount(marginCount: 0, size: CGSize(width: 375, height: 667))
        defer { none.close() }
        let noneDock = try await settledFrames(in: none, names: ["dock"])["dock"]!
        XCTAssertEqual(manyDock.height, noneDock.height, accuracy: 0.5, "The dock changes height with the number of Margins")
        XCTAssertEqual(manyDock.maxY, noneDock.maxY, accuracy: 0.5)
    }

    // MARK: - Mounting

    private static func session(marginCount: Int) -> LiveSession {
        let start = Date(timeIntervalSinceNow: -4_000)
        let margins = (0..<marginCount).map { index in
            LiveSessionMargin(
                id: "m\(index)", text: "A Margin worth keeping, number \(index), long enough to need a second line on a small phone.",
                markedAt: start.addingTimeInterval(Double(index) * 60), sessionOffsetMs: index * 60_000)
        }
        return LiveSession(id: "live-dock-test", kind: .meeting, title: "Budget review", startedAt: start, startPositionMs: 0, margins: margins)
    }

    private func mount(marginCount: Int, size: CGSize) throws -> Mounted {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let session = Self.session(marginCount: marginCount)
        let dock = LiveSessionDock(
            pane: .constant(.margins), marginCount: marginCount, isRunning: true, resumeUntil: nil,
            clock: { _ in LiveSessionDockClock(main: "1:06:40", caption: "Meeting · session 1:06:40", accessibility: "Session time 1:06:40") },
            end: {}, resume: {}, record: {}, write: {})
        let stage = LiveSessionStage(
            pane: LiveSessionMarginsPane(session: session, select: { _ in }, pauseOtherAudio: {}).background(Probe(name: "pane")),
            pill: EmptyView(),
            dock: dock.background(Probe(name: "dock")))
        let host = UIHostingController(rootView: AnyView(stage.background(AppColors.listeningBackground)))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return Mounted(window: window, previousKeyWindow: previousKeyWindow)
    }

    private func settledFrames(in mounted: Mounted, names: [String]) async throws -> [String: CGRect] {
        var last: [String: CGRect] = [:]
        var steady = 0
        for _ in 0..<150 {
            mounted.window.layoutIfNeeded()
            var frames: [String: CGRect] = [:]
            for probe in Self.probes(in: mounted.window) where names.contains(probe.name) && probe.window != nil {
                frames[probe.name] = probe.convert(probe.bounds, to: mounted.window)
            }
            if frames.count == names.count, frames.values.allSatisfy({ $0.height > 0 }), frames == last {
                steady += 1
                if steady >= 3 { return frames }
            } else {
                steady = 0
            }
            last = frames
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("The probes \(names) never settled; last frames: \(last)")
        throw NotSettled()
    }

    private static func probes(in view: UIView) -> [ProbeUIView] {
        var found = [ProbeUIView]()
        if let probe = view as? ProbeUIView { found.append(probe) }
        for child in view.subviews { found += probes(in: child) }
        return found
    }

    private struct NotSettled: Error {}

    @MainActor
    private struct Mounted {
        let window: UIWindow
        let previousKeyWindow: UIWindow?

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
    }
}

private final class ProbeUIView: UIView {
    var name = ""
}

private struct Probe: UIViewRepresentable {
    let name: String

    func makeUIView(context: Context) -> ProbeUIView {
        let view = ProbeUIView()
        view.name = name
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeUIView, context: Context) {
        view.name = name
    }
}
