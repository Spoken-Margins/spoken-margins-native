#if SM_SHARE_LINK_CREATION
import SessionKit
import SwiftUI
import XCTest
@testable import SpokenMarginsApp

/// #487: the recipient preview's share actions with "Share as link" hidden, offered, and after a failed upload. The
/// real buttons are laid out at the narrowest phone width, and each rendering is attached so the run's result bundle
/// holds a picture of every state. These are renderings of the views, not screenshots of the whole sender flow.
@MainActor
final class ShareAsLinkRenderingTests: XCTestCase {
    /// The preview's width on a 375 pt-wide phone, the narrowest iOS 26 runs on, less 16 pt of padding on each side.
    private static let narrowestWidth: CGFloat = 343

    private enum LinkState: String {
        /// What the preview shows when the server's `links` switch is off: `ShareLinkSendControl` draws nothing, so
        /// this renders no link row. The switch itself is `ShareLinkSender.isOffered`, not exercised here.
        case hidden
        case offered
        case failed
    }

    func testTheLinkButtonSitsUnderTheFileShareAndAFailedUploadAddsItsLine() throws {
        for size in [DynamicTypeSize.large, .accessibility5] {
            let hidden = try render(.hidden, size: size)
            let offered = try render(.offered, size: size)
            let failed = try render(.failed, size: size)

            // The link row adds a button and 20 pt of spacing; the failure adds a line of text and 8 pt.
            XCTAssertGreaterThan(offered.height, hidden.height + 30, "\(size): \"Share as link\" did not appear under the file share")
            XCTAssertGreaterThan(failed.height, offered.height + 15, "\(size): a failed upload did not add its line")
        }
    }

    private func render(_ state: LinkState, size: DynamicTypeSize) throws -> CGSize {
        let actions = Build23VerifiedShareActions(isFileShareEnabled: true, onEdit: {}, onShareFile: {}) {
            switch state {
            case .hidden:
                EmptyView()
            case .offered:
                ShareLinkSendRow(state: .idle, companionNote: nil, makeLink: {})
            case .failed:
                ShareLinkSendRow(state: .useFile(ShareLinkFallback.unavailable.message), companionNote: nil, makeLink: {})
            }
        }
        .padding(.vertical, 16)
        .environment(\.dynamicTypeSize, size)
        .background(Color(uiColor: .systemBackground))

        let renderer = ImageRenderer(content: actions)
        renderer.proposedSize = ProposedViewSize(width: Self.narrowestWidth, height: nil)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "\(state) at \(size) did not render")
        let attachment = XCTAttachment(image: image)
        attachment.name = "share-as-link-\(state.rawValue)-\(size)-\(Int(image.size.width))x\(Int(image.size.height))"
        attachment.lifetime = .keepAlways
        add(attachment)
        return image.size
    }
}
#endif
