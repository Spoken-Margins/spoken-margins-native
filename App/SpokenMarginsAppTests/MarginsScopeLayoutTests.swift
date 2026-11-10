import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Measures the Margins scope control with a short and a long item title. A long title once wrapped through
/// several lines behind the Mine / Starred / Shared buttons and into the group heading (#1631); the control now
/// keeps one line, so its height must not depend on the title and it must stay inside the width it is offered.
/// The row is hosted on its own, so the measure doesn't depend on the screen's accessibility tree.
@MainActor
final class MarginsScopeLayoutTests: XCTestCase {
    private static let longTitle = "How to be more ambitious: A tutorial for humans with models, and why a very long title should never cover the filters"
    private static let phoneWidths: [(name: String, width: CGFloat)] = [("iPhone SE class", 375), ("iPhone 16 class", 393)]
    private static let textSizes: [(name: String, size: DynamicTypeSize)] = [
        ("default text", .large),
        ("largest accessibility text", .accessibility5),
    ]

    func testALongItemTitleKeepsTheScopeControlOneLineAndInsideItsWidth() {
        for phone in Self.phoneWidths {
            for text in Self.textSizes {
                let label = "\(phone.name), \(text.name)"
                let offered = CGSize(width: phone.width - 32, height: 2_000)
                let short = size(title: "Short", offered: offered, textSize: text.size)
                let long = size(title: Self.longTitle, offered: offered, textSize: text.size)
                XCTAssertEqual(long.height, short.height, accuracy: 1,
                               "\(label): the long title made the scope row \(long.height) points tall, not \(short.height)")
                XCTAssertLessThanOrEqual(long.width, offered.width + 0.5,
                                         "\(label): the scope row is \(long.width) points wide in \(offered.width)")
            }
        }
    }

    private func size(title: String, offered: CGSize, textSize: DynamicTypeSize) -> CGSize {
        let row = MarginsScopeRow(
            title: title, countText: "12 Margins", selection: .constant("scope-item"),
            collections: [], items: [LibraryItemRow(id: "scope-item", title: title, status: "ready", canDelete: true)]
        )
        let host = UIHostingController(rootView: row.environment(\.dynamicTypeSize, textSize))
        return host.sizeThatFits(in: offered)
    }
}
