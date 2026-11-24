import SwiftUI
import UIKit
import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #4739: at first launch with the largest text size and dark mode, the Now header's scroll visibility fed the toolbar,
/// whose size fed the scroll visibility, at 100% CPU. The leading item must be in the bar whether or not the header
/// is on screen. Hosts the real toolbar content in a navigation controller and reads the bar items UIKit was given.
@MainActor
final class PlaybackLeadingToolbarTests: XCTestCase {
    private final class Driver: ObservableObject {
        @Published var headerIsVisible = true
        var bodyEvaluations = 0
    }

    private struct Host: View {
        @ObservedObject var driver: Driver
        let pane: PlaybackLeadingControl.Pane
        var body: some View {
            let _ = { driver.bodyEvaluations += 1 }()
            Color.clear
                .toolbar {
                    PlaybackLeadingToolbar(
                        pane: pane, timelineEditorHasFocus: false,
                        nowHeaderIsVisible: driver.headerIsVisible, returnToNow: {}
                    ) { Image(systemName: "chevron.left") }
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

    func testLeadingItemIsInTheBarWhetherOrNotTheNowHeaderIsVisible() throws {
        let driver = Driver()
        let host = UIHostingController(rootView: Host(driver: driver, pane: .now)
            .dynamicTypeSize(.accessibility3).preferredColorScheme(.dark))
        let nav = UINavigationController(rootViewController: host)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav
        window.makeKeyAndVisible()

        settle(nav) { !leadingItems(nav).isEmpty }
        let whileVisible = leadingItems(nav)
        XCTAssertFalse(whileVisible.isEmpty, "the Library arrow is in the bar while the header shows (hidden, not removed)")

        driver.headerIsVisible = false
        let evaluationsBefore = driver.bodyEvaluations
        settle(nav) { driver.bodyEvaluations > evaluationsBefore }
        for _ in 0..<5 { nav.view.layoutIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let whileHidden = leadingItems(nav)
        XCTAssertEqual(whileHidden.count, whileVisible.count, "same number of leading items once the header scrolls away")
        XCTAssertTrue(zip(whileVisible, whileHidden).allSatisfy { $0 === $1 }, "the same bar items, not new ones")

        driver.headerIsVisible = true
        for _ in 0..<5 { nav.view.layoutIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(leadingItems(nav).count, whileVisible.count, "and the same when it returns")
        XCTAssertLessThan(driver.bodyEvaluations, 40, "no layout loop: a few evaluations for two flips, not hundreds")
    }
}
