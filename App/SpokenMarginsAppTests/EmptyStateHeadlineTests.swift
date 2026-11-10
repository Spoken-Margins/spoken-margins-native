import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #3837: on an empty Following tab the headline read "You’re not following anythin…" at the default text size. Every
/// empty state (Library, Margins, Following, Timeline) draws through `SMExperienceEmptyState`, so one test covers them.
///
/// The card is at least 260 pt tall, so a clipped headline and a short one measure the same. The test therefore draws a
/// headline long enough to need many lines, at the phone's 393 pt width, and checks the card grew past its minimum: a
/// headline held to one line could not make it.
@MainActor
final class EmptyStateHeadlineTests: XCTestCase {
    private static let width: CGFloat = 393
    private static let minimumHeight: CGFloat = 260

    private func height(title: String, size: DynamicTypeSize) -> CGFloat {
        let view = SMExperienceEmptyState(
            systemImage: "dot.radiowaves.left.and.right", title: title, detail: "Follow a podcast or a writer.",
            actionTitle: "Paste a feed link", action: {})
        return UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: Self.width, height: 4_000)).height
    }

    func testALongHeadlineWrapsInsteadOfClippingAtDefaultAndLargeText() {
        let words = Array(repeating: "You’re not following anything yet", count: 14).joined(separator: ", ")
        for (size, label) in [(DynamicTypeSize.large, "default"), (.accessibility3, "accessibility3")] {
            let tall = height(title: words, size: size)
            XCTAssertGreaterThan(tall, Self.minimumHeight + 40,
                                 "\(label): a \(words.count)-character headline drew a \(tall) pt card, so it did not wrap")
        }
    }
}
