import XCTest
@testable import SessionKit

/// #3854: "Review Margins" beside the two start choices was a grey fill with grey text, which reads as disabled.
final class ItemMarginsLinkStyleTests: XCTestCase {
    func testBesideTheStartChoicesItIsAnOutlineNotAGreyFill() {
        XCTAssertEqual(ItemMarginsLinkStyle.style(quiet: true), .outline)
    }

    func testAlongItIsTheEvergreenBorderedButton() {
        XCTAssertEqual(ItemMarginsLinkStyle.style(quiet: false), .bordered)
    }

    /// The outline's evergreen text must stay readable on the screen's bone background, light and dark.
    func testEvergreenTextIsAuditedAsReadableOnBoneAndOnAPanel() {
        for name in ["evergreen text on bone", "evergreen text on panel"] {
            let pair = AppColorContrastAudit.textBackgroundPairs.first { $0.name == name }
            XCTAssertNotNil(pair, "\(name) is audited")
            guard let pair else { continue }
            XCTAssertGreaterThanOrEqual(pair.minimumRatio, 4.5)
            for (foreground, background) in [(pair.foreground.light, pair.background.light), (pair.foreground.dark, pair.background.dark)] {
                XCTAssertGreaterThanOrEqual(
                    AppColorContrastAudit.contrastRatio(foreground: foreground, background: background), 4.5, name)
            }
        }
    }
}
