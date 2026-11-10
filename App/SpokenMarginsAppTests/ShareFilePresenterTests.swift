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

    /// On an iPad the sheet is a popover and crashes without an anchor. An iPhone has no popover, so there is nothing to
    /// check there.
    func testTheSheetIsAnchoredWhereItIsAPopover() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Only an iPad shows the share sheet as a popover")
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics.json")

        let controller = ShareFilePresenter.makeController(fileURL: url, anchoredIn: view)

        let popover = try XCTUnwrap(controller.popoverPresentationController)
        XCTAssertTrue(popover.sourceView === view)
        XCTAssertEqual(popover.sourceRect.origin.x, view.bounds.midX)
        XCTAssertEqual(popover.permittedArrowDirections, [])
    }
}
