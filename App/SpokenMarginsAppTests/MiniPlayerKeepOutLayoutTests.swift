import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Mounts `MiniPlayerDock` around a NavigationStack with a pushed screen, the shape of Following → Manage Feeds →
/// Import from another app, and measures where the pill and each screen's pinned bottom bar land in the window.
/// The pill once covered the pushed screen's "Choose OPML file" bar, because the pill's inset sat outside the stack
/// and didn't reach pushed screens (#1716). The next fix stacked the pill under the content, which kept the bar clear
/// but left a solid chin with nothing behind the pill (#1717). The owner wants both: the pill floats, and every
/// screen keeps its bottom clear of it. UIKit probes give window coordinates, so the measure doesn't depend on how
/// SwiftUI's coordinate spaces cross the navigation controller's hosting boundaries.
@MainActor
final class MiniPlayerKeepOutLayoutTests: XCTestCase {
    private static let pillHeight: CGFloat = 56
    private static let barHeight: CGFloat = 44

    func testAPushedScreensBottomBarSitsAboveTheFloatingPill() async throws {
        let mounted = try mount(pushes: true, keepsOut: true)
        defer { mounted.close() }
        let frames = try await settledFrames(in: mounted, names: ["pill", "stack", "pushed.bar"])
        let pill = frames["pill"]!, bar = frames["pushed.bar"]!, stack = frames["stack"]!

        XCTAssertLessThanOrEqual(bar.maxY, pill.minY - MiniPlayerDock<EmptyView, EmptyView>.gap + 0.5,
                                 "The pushed screen's bottom bar ends at \(bar.maxY); the pill starts at \(pill.minY)")
        XCTAssertGreaterThanOrEqual(stack.maxY, pill.maxY - 0.5,
                                    "The navigation stack ends at \(stack.maxY), above the pill's bottom \(pill.maxY): the pill is docked under the content instead of floating over it")
    }

    func testTheStackRootsBottomBarSitsAboveTheFloatingPill() async throws {
        let mounted = try mount(pushes: false, keepsOut: true)
        defer { mounted.close() }
        let frames = try await settledFrames(in: mounted, names: ["pill", "stack", "root.bar"])
        let pill = frames["pill"]!, bar = frames["root.bar"]!, stack = frames["stack"]!

        XCTAssertLessThanOrEqual(bar.maxY, pill.minY - MiniPlayerDock<EmptyView, EmptyView>.gap + 0.5,
                                 "The root screen's bottom bar ends at \(bar.maxY); the pill starts at \(pill.minY)")
        XCTAssertGreaterThanOrEqual(stack.maxY, pill.maxY - 0.5, "The pill must float over the content")
    }

    /// The control: without the keep-out, the pushed bar runs under the pill. It shows the measure can see a covered
    /// bar, and that the pill really is drawn over the pushed screen rather than beside it.
    func testWithoutTheKeepOutThePushedBarRunsUnderThePill() async throws {
        let mounted = try mount(pushes: true, keepsOut: false)
        defer { mounted.close() }
        let frames = try await settledFrames(in: mounted, names: ["pill", "pushed.bar"])
        XCTAssertGreaterThan(frames["pushed.bar"]!.maxY, frames["pill"]!.minY,
                             "With no keep-out the pushed bar should end under the floating pill")
    }

    func testAHiddenPillLeavesNoGapAtTheBottom() async throws {
        let mounted = try mount(pushes: true, keepsOut: true, showsPill: false)
        defer { mounted.close() }
        let frames = try await settledFrames(in: mounted, names: ["pushed.bar"])
        let safeBottom = mounted.window.bounds.height - mounted.window.safeAreaInsets.bottom
        XCTAssertEqual(frames["pushed.bar"]!.maxY, safeBottom, accuracy: 0.5,
                       "With the pill hidden, the pushed bar should sit on the safe area's bottom edge")
    }

    // MARK: - Mounting

    private func mount(pushes: Bool, keepsOut: Bool, showsPill: Bool = true) throws -> Mounted {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let root = MiniPlayerDock(showsMiniPlayer: showsPill) {
            Probe(name: "pill").frame(height: Self.pillHeight)
        } content: {
            NavigationStack {
                Screen(barName: "root.bar", keepsOut: keepsOut)
                    .navigationDestination(isPresented: .constant(pushes)) {
                        Screen(barName: "pushed.bar", keepsOut: keepsOut)
                    }
            }
            .background(Probe(name: "stack"))
        }
        let host = UIHostingController(rootView: AnyView(root))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        return Mounted(window: window, previousKeyWindow: previousKeyWindow)
    }

    /// Window frames of the named probes once they are laid out and have stopped moving.
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

/// A screen shaped like the OPML import screen: a list with a bar pinned to its bottom edge.
private struct Screen: View {
    let barName: String
    let keepsOut: Bool

    var body: some View {
        let screen = List(0..<40, id: \.self) { Text("Row \($0)") }
            .safeAreaInset(edge: .bottom) {
                Probe(name: barName).frame(height: 44)
            }
        if keepsOut {
            screen.miniPlayerKeepOut()
        } else {
            screen
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
