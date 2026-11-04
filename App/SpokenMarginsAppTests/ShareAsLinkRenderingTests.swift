#if SM_SHARE_LINK_CREATION
import SessionKit
import SwiftUI
import XCTest
@testable import SpokenMarginsApp

/// #487: the recipient preview's share actions with "Share as link" hidden, offered, and after a failed upload. The
/// real buttons are laid out at the narrowest phone width, and each rendering is attached so the run's result bundle
/// holds the screenshots of every state.
@MainActor
final class ShareAsLinkRenderingTests: XCTestCase {
    /// The preview's width on a 375 pt-wide phone, the narrowest iOS 26 runs on, less 16 pt of padding on each side.
    private static let narrowestWidth: CGFloat = 343

    private enum LinkState: String {
        /// The server's `links` switch is off, so `ShareLinkSendControl` draws nothing.
        case hidden
        case offered
        case failed
    }

    func testTheLinkButtonSitsUnderTheFileShareAndAFailedUploadAddsOneLineAndKeepsTheFileShare() throws {
        let hidden = try render(.hidden, size: .large)
        let offered = try render(.offered, size: .large)
        let failed = try render(.failed, size: .large)

        XCTAssertGreaterThan(offered.height, hidden.height + 20, "\"Share as link\" did not appear under the file share")
        XCTAssertGreaterThan(failed.height, offered.height + 10, "a failed upload did not add its line")
        // The failed state keeps both buttons, so it can only grow: nothing it had is taken away.
        XCTAssertEqual(failed.width, offered.width, accuracy: 0.5)
    }

    func testEveryStateFitsTheNarrowestPhoneAtEveryTextSize() throws {
        for state in [LinkState.hidden, .offered, .failed] {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let rendered = try render(state, size: size)
                XCTAssertLessThanOrEqual(
                    rendered.width, Self.narrowestWidth + 0.5,
                    "\(state) at \(size): wider than the phone, so a button or the line is cut off"
                )
            }
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
