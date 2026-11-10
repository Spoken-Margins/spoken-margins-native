import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #4026: the diagnostics and listening-signals share sheets are presented from UIKit, over the front-most view
/// controller, so a redraw of the Settings form cannot reload them.
@MainActor
final class ShareFilePresenterTests: XCTestCase {
    func testTheSheetGoesOverTheFrontMostPresentedController() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let root = UIViewController()
        let first = UIViewController()
        let second = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKeyAndVisible()
        }

        XCTAssertTrue(ShareFilePresenter.topViewController(from: root) === root)

        let presented = expectation(description: "presented")
        root.present(first, animated: false) {
            first.present(second, animated: false) { presented.fulfill() }
        }
        wait(for: [presented], timeout: 5)

        XCTAssertTrue(ShareFilePresenter.topViewController(from: root) === second)
        XCTAssertNil(ShareFilePresenter.topViewController(from: nil))
    }

    func testTheSheetCarriesTheFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics.json")
        XCTAssertEqual(ShareFilePresenter.activityItems(for: url).compactMap { $0 as? URL }, [url])
    }

    /// A view controller set to `.popover` has a popover presentation controller on any device, so this runs everywhere
    /// (the lane counts a skipped test as a fault).
    func testThePopoverIsAnchoredAtTheCentreWithNoArrow() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let controller = UIViewController()
        controller.modalPresentationStyle = .popover
        let popover = try XCTUnwrap(controller.popoverPresentationController)

        ShareFilePresenter.anchor(popover, in: view)

        XCTAssertTrue(popover.sourceView === view)
        XCTAssertEqual(popover.sourceRect, CGRect(x: 196.5, y: 426, width: 0, height: 0))
        XCTAssertEqual(popover.permittedArrowDirections, [])
    }

    func testNoPopoverMeansNothingToAnchor() {
        ShareFilePresenter.anchor(nil, in: UIView())
    }
}
