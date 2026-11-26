import SwiftUI
import UIKit
import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// Hosts the real toolbar content in a navigation controller and reads the bar items UIKit was given.
///
/// #5329: on Now the bar held an invisible copy of the Library arrow, and iOS 26 drew an empty glass pill around it.
/// The arrow is now drawn in the corner on Now. #4739: at first launch with the largest text size and dark mode, scroll
/// state fed the toolbar, whose size fed the scroll, at 100% CPU; the bar now takes no scroll input, and this checks
/// that hosting it at AX3 in dark mode settles in a few passes.
@MainActor
final class PlaybackLeadingToolbarTests: XCTestCase {
    private final class Driver: ObservableObject {
        var bodyEvaluations = 0
    }

    private struct Host: View {
        @ObservedObject var driver: Driver
        let pane: PlaybackLeadingControl.Pane
        var body: some View {
            let _ = { driver.bodyEvaluations += 1 }()
            Color.clear
                .toolbar {
                    PlaybackLeadingToolbar(pane: pane, timelineEditorHasFocus: false, returnToNow: {}) {
                        Image(systemName: "chevron.left")
                            .accessibilityIdentifier(PlaybackLeadingControl.libraryExitIdentifier)
                    }
                }
        }
    }

    /// Lays out and turns the run loop until the condition holds; the deadline is only a ceiling.
    private func settle(_ nav: UINavigationController, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline {
            nav.view.setNeedsLayout()
            nav.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func leadingItems(_ nav: UINavigationController) -> [UIBarButtonItem] {
        guard let item = nav.topViewController?.navigationItem else { return [] }
        return (item.leftBarButtonItems ?? []) + item.leadingItemGroups.flatMap(\.barButtonItems)
    }

    func testNowHasOneLeadingItemAndSettlesAtTheLargestTextSize() throws {
        let driver = Driver()
        let host = UIHostingController(rootView: Host(driver: driver, pane: .now)
            .dynamicTypeSize(.accessibility3).preferredColorScheme(.dark))
        let nav = UINavigationController(rootViewController: host)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav
        window.makeKeyAndVisible()

        settle(nav) { !leadingItems(nav).isEmpty }
        XCTAssertEqual(leadingItems(nav).count, 1, "the Library arrow is the one leading item on Now")
        for _ in 0..<10 { nav.view.layoutIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertLessThan(driver.bodyEvaluations, 20, "no layout loop: a few evaluations, not hundreds")
    }
}
