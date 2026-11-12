#if SM_SHARE_LINK_CREATION
import DeviceCheck
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

    /// #4135: the one place Apple's `DCError.invalidKey` becomes `keyUnusable`, the only signing failure that replaces
    /// the key. Every other error, `DCError` or not, passes through and leaves the install's identity alone.
    func testOnlyAnInvalidKeyBecomesKeyUnusable() {
        XCTAssertEqual(
            AppAttestDeviceProvider.signingFailure(DCError(.invalidKey)) as? AppAttestFailure, .keyUnusable)
        for code in [DCError.Code.featureUnsupported, .invalidInput, .serverUnavailable] {
            let mapped = AppAttestDeviceProvider.signingFailure(DCError(code))
            XCTAssertNil(mapped as? AppAttestFailure, "a \(code) is not a lost key")
            XCTAssertEqual((mapped as? DCError)?.code, code)
        }
        XCTAssertNil(AppAttestDeviceProvider.signingFailure(URLError(.cancelled)) as? AppAttestFailure)
    }

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

    /// #3787: a link goes out with a sentence, so the friend does not get a bare address. The sentence and the whole
    /// link, key included, are one text, so no app can keep one and drop the other.
    func testTheLinkSheetCarriesTheSentenceAndTheWholeLinkAsOneText() throws {
        let link = URL(string: "https://example.test/l/abc#k")!
        let alone = ShareLinkActivityView.activityItems(link: link, companionFile: nil)
        XCTAssertEqual(alone.count, 1)
        let text = try XCTUnwrap(alone.first as? String)
        XCTAssertTrue(text.hasPrefix(ShareLinkMessage.sentence))
        XCTAssertTrue(text.hasSuffix("https://example.test/l/abc#k"))

        let file = URL(fileURLWithPath: "/tmp/margins.spokenmargins")
        let withFile = ShareLinkActivityView.activityItems(link: link, companionFile: file)
        XCTAssertEqual(withFile.count, 2, "the file still goes in the same message as the link")
        XCTAssertEqual(withFile.first as? String, text)
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

    func testTheReviewStepButtonsFitAtEveryTextSize() throws {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility5] {
            let back = try render(
                Build23BackToSelectionButton(identifier: "back", action: {}), name: "back", size: size
            )
            let file = try render(
                Build23SendFileButton(isEnabled: true, identifier: "file", action: {}), name: "send-file", size: size
            )
            let preview = try render(Build23PreviewRow(action: {}), name: "preview-row", size: size)
            for (label, rendered) in [("Back to selection", back), ("Send as a file", file), ("Preview row", preview)] {
                XCTAssertLessThanOrEqual(rendered.width, Self.narrowestWidth + 1, "\(size): \(label) ran off the screen")
                XCTAssertAtLeastPoints(rendered.height, 44, "\(size): \(label) is under 44 points high")
            }
            // At ordinary sizes the preview label takes at most two lines, not the five it broke into in a shared row (#3896).
            if size != .accessibility5 {
                XCTAssertLessThan(preview.height, 70, "\(size): the preview row wrapped")
            }
        }
    }

    func testThePreviewStepDrawsShareYourMarginsOnlyWithoutLinks() throws {
        for size in [DynamicTypeSize.large, .accessibility5] {
            let withoutLinks = try render(
                Build23VerifiedShareActions(isFileShareEnabled: true, onShareFile: {}),
                name: "file-first", size: size
            )
            let withLinks = try render(
                Build23VerifiedShareActions(isFileShareEnabled: true, fileIsSecondChoice: true, onShareFile: {}),
                name: "file-second", size: size
            )
            XCTAssertGreaterThan(withoutLinks.height, 20, "\(size): Share your Margins did not render")
            XCTAssertLessThan(withLinks.height, 4, "\(size): the pinned bar's Send as a file is drawn twice")
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
