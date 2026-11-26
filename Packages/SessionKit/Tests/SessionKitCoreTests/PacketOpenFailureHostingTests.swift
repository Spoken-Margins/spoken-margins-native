import XCTest
@testable import SessionKit

final class PacketOpenFailureHostingTests: XCTestCase {
    func testTheDrawerShowsTheFailureWhileItIsUpAndTheRootOtherwise() {
        XCTAssertEqual(PacketOpenFailureHost.hosting(drawerIsPresented: true), .drawer)
        XCTAssertEqual(PacketOpenFailureHost.hosting(drawerIsPresented: false), .root)
    }

    func testExactlyOneHostOwnsTheSheetForEveryDrawerState() {
        for drawerIsPresented in [true, false] {
            let host = PacketOpenFailureHost.hosting(drawerIsPresented: drawerIsPresented)
            let hosts = [PacketOpenFailureHost.root, .drawer].filter { $0 == host }
            XCTAssertEqual(hosts.count, 1, "drawer up: \(drawerIsPresented)")
        }
    }

    /// The path the audit on PR #4659 found closed: a failed paste over a drawer that has picks. The drawer hosts the sheet
    /// (the root cannot present over it), and closing it leaves the notice that tells the drawer no friend's item is coming.
    func testAFailureOverAnUpDrawerIsShownByTheDrawerAndClosingItNotifiesTheDrawer() {
        var state = PacketOpenFailureSheetState()
        state.present(PacketOpenFailureSheetContent(unparsedShareHostURL: URL(string: "https://share.example/l/ab12ab12ab12")!),
                      canRetry: false)
        XCTAssertNotNil(state.presented)
        XCTAssertEqual(PacketOpenFailureHost.hosting(drawerIsPresented: true), .drawer)
        XCTAssertFalse(state.sheetDismissed(), "no notice while the sheet is still up")
        _ = state.close()
        XCTAssertTrue(state.sheetDismissed(), "the drawer's sheet has left: tell the drawer once")
        XCTAssertFalse(state.sheetDismissed())
    }
}
