import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #4026: the diagnostics and listening-signals share sheets are presented from UIKit, over the front-most view
/// controller, so a redraw of the Settings form cannot reload them.
@MainActor
final class ShareFilePresenterTests: XCTestCase {
    func testTheSheetGoesOverTheFrontMostPresentedController() {
        let root = UIViewController()
        let first = UIViewController()
        let second = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        XCTAssertTrue(ShareFilePresenter.topViewController(from: root) === root)

        let presented = expectation(description: "presented")
        root.present(first, animated: false) {
            first.present(second, animated: false) { presented.fulfill() }
        }
        wait(for: [presented], timeout: 5)

        XCTAssertTrue(ShareFilePresenter.topViewController(from: root) === second)
        XCTAssertNil(ShareFilePresenter.topViewController(from: nil))
    }

    func testTheSheetCarriesTheFileAndIsAnchoredForIPad() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics.json")

        let controller = ShareFilePresenter.makeController(fileURL: url, anchoredIn: view)

        XCTAssertEqual(controller.activityItems.compactMap { $0 as? URL }, [url])
        if let popover = controller.popoverPresentationController {
            XCTAssertTrue(popover.sourceView === view)
            XCTAssertEqual(popover.sourceRect.origin.x, view.bounds.midX)
            XCTAssertEqual(popover.permittedArrowDirections, [])
        }
    }
}
