#if SM_SHARE_LINK_CREATION
import SessionKit
import SwiftUI
import XCTest
@testable import SpokenMarginsApp

/// #487, #3750: what a build that makes links draws around its Share button. The pinned Share button makes the link;
/// under it, nothing while idle, one line after a failed upload, one line when the file goes with the link. The
/// recipient preview's own file share becomes the second choice, "Send as a file". Each rendering is attached so the
/// run's result bundle holds a picture of every state. These are renderings of the views, not screenshots of the flow.
@MainActor
final class ShareAsLinkRenderingTests: XCTestCase {
    /// The preview's width on a 375 pt-wide phone, the narrowest iOS 26 runs on, less 16 pt of padding on each side.
    private static let narrowestWidth: CGFloat = 343

    /// #3751 audit: sharing by link recorded no share signal (#483), though the file sheet does. The link's sheet now
    /// reports a completed share, and only a completed one.
    func testTheLinkSheetReportsACompletedShareOnly() {
        var shared = 0
        let sheet = ShareLinkActivityView(link: URL(string: "https://example.test/l/abc#k")!, companionFile: nil) { shared += 1 }
        let controller = sheet.makeController()
        controller.completionWithItemsHandler?(nil, false, nil, nil)
        XCTAssertEqual(shared, 0, "a cancelled sheet is not a share")
        controller.completionWithItemsHandler?(nil, true, nil, nil)
        XCTAssertEqual(shared, 1)
    }

    func testTheStatusLinesAreEmptyUntilALinkFailsOrNeedsItsFile() throws {
        for size in [DynamicTypeSize.large, .accessibility5] {
            let idle = try render(ShareLinkStatusLines(state: .idle, companionNote: nil), name: "status-idle", size: size)
            let failed = try render(
                ShareLinkStatusLines(state: .useFile(ShareLinkFallback.unavailable.message), companionNote: nil),
                name: "status-failed", size: size
            )
            let companion = try render(
                ShareLinkStatusLines(state: .making, companionNote: "The file goes in the same message as the link."),
                name: "status-companion", size: size
            )

            XCTAssertLessThan(idle.height, 4, "\(size): an idle Share link drew a line under the button")
            XCTAssertGreaterThan(failed.height, 15, "\(size): a failed upload did not say to send the file")
            XCTAssertGreaterThan(companion.height, 15, "\(size): the companion-file note did not appear")
        }
    }

    func testTheFileShareFitsAsTheSecondChoiceAtEveryTextSize() throws {
        for size in [DynamicTypeSize.large, .accessibility5] {
            let first = try render(
                Build23VerifiedShareActions(isFileShareEnabled: true, onEdit: {}, onShareFile: {}),
                name: "file-first", size: size
            )
            let second = try render(
                Build23VerifiedShareActions(isFileShareEnabled: true, fileIsSecondChoice: true, onEdit: {}, onShareFile: {}),
                name: "file-second", size: size
            )
            XCTAssertLessThanOrEqual(second.width, Self.narrowestWidth + 1, "\(size): Send as a file ran off the screen")
            XCTAssertGreaterThan(second.height, 20, "\(size): Send as a file did not render")
            XCTAssertGreaterThan(first.height, 20, "\(size): Share your Margins did not render")
        }
    }

    private func render(_ view: some View, name: String, size: DynamicTypeSize) throws -> CGSize {
        let content = view
            .environment(\.dynamicTypeSize, size)
            .background(Color(uiColor: .systemBackground))

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: Self.narrowestWidth, height: nil)
        renderer.scale = 2
        guard let image = renderer.uiImage else {
            // An empty view renders no image at all; that is a zero size, not a failure.
            return .zero
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "share-as-link-\(name)-\(size)-\(Int(image.size.width))x\(Int(image.size.height))"
        attachment.lifetime = .keepAlways
        add(attachment)
        return CGSize(width: image.size.width, height: image.size.height)
    }
}
#endif
