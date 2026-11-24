import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// The item screen's pinned start area keeps a height budget at the accessibility text sizes (#5110).
///
/// At AX5 the pinned area used to hold the "preparing audio" line, the friend's-arrival line, the main button and the
/// second choice, each at full size. With the mini player under it, it covered about half the screen and clipped the
/// content above (Test Desk, `main` 6e9c2d1e6, 2026-11-23). Now only the main button is pinned there, its text capped.
///
/// The controls are drawn with no model at an iPhone 17's 402 pt width, minus the screen's 18 pt side padding, as
/// `FootnoteCardLayoutTests` draws its card. The test runs in a simulator only.
@MainActor
final class ItemStartControlsLayoutTests: XCTestCase {
    private static let width: CGFloat = 402 - 2 * 18
    /// The pinned area's budget at the accessibility sizes, before the screen's 10 pt padding above and below: about a
    /// sixth of an iPhone 17's 874 pt height (a three-line capped main button fits), which leaves at least half the screen for content with the mini player.
    private static let accessibilityBudget: CGFloat = 150

    private static let friend = ItemListeningChoices.WaitingMargin(senderName: "Samantha", audioDurationMs: 95_000, transcript: "")

    /// Every state the pinned area can show: the plain button, the two friend choices, and the two "behind the place"
    /// choices, each with the longest words they can carry.
    private static let states: [(label: String, choices: ItemListeningChoices)] = [
        ("Continue", ItemListeningChoices(unheardFriendMargins: [], hasFinishedSession: false, hasContinuationSession: true, isPreparingAudio: false)),
        ("Listen now", ItemListeningChoices(unheardFriendMargins: [], hasFinishedSession: false, hasContinuationSession: false, isPreparingAudio: true)),
        ("Play + Skip to", ItemListeningChoices(
            unheardFriendMargins: [friend, friend, friend], hasFinishedSession: false, hasContinuationSession: true, isPreparingAudio: false)),
        ("Hear first + Listen without", ItemListeningChoices(
            unheardFriendMargins: [friend, friend], marginsBehindPlace: [friend, friend],
            hasFinishedSession: false, hasContinuationSession: true, isPreparingAudio: false)),
        ("Hear first + Play from the start", ItemListeningChoices(
            unheardFriendMargins: [friend], marginsBehindPlace: [friend], placeIsAtEnd: true,
            hasFinishedSession: true, hasContinuationSession: true, isPreparingAudio: false)),
    ]

    private static let preparing = ItemStartControls.Preparing(showsSpinner: true, description: "Preparing audio for this article…")
    private static let arrivalLine = "Samantha's Margins are still arriving. Your tap is kept and starts as soon as they're ready."

    private static func height(
        _ placement: ItemStartControls.Placement, choices: ItemListeningChoices, size: DynamicTypeSize,
        preparing: ItemStartControls.Preparing? = ItemStartControlsLayoutTests.preparing,
        arrivalLine: String? = ItemStartControlsLayoutTests.arrivalLine
    ) -> CGFloat {
        let controls = ItemStartControls(
            placement: placement, layout: ItemStartControlsLayout(accessibilityTextSize: size.isAccessibilitySize),
            preparing: preparing, arrivalLine: arrivalLine, choices: choices, onMainButton: {}, onSecondChoice: {})
        return UIHostingController(
            rootView: VStack(alignment: .leading, spacing: 8) { controls }
                .frame(width: width)
                .environment(\.dynamicTypeSize, size)
        )
        .sizeThatFits(in: CGSize(width: width, height: 4_000)).height
    }

    func testThePinnedAreaKeepsItsBudgetAtTheAccessibilitySizes() {
        for size in [DynamicTypeSize.accessibility3, .accessibility5] {
            for (label, choices) in Self.states {
                let pinned = Self.height(.pinned, choices: choices, size: size)
                XCTAssertLessThanOrEqual(pinned, Self.accessibilityBudget,
                                         "\(label) at \(size): the pinned area is \(pinned) pt tall, budget \(Self.accessibilityBudget) pt")
                XCTAssertGreaterThanOrEqual(pinned, TapTarget.minimum, "\(label) at \(size): the pinned main button is gone")
            }
        }
    }

    /// What leaves the pinned area at the accessibility sizes is still on the screen, at the top of the content.
    func testWhatLeavesThePinnedAreaIsDrawnInTheContent() {
        for (label, choices) in Self.states {
            let inline = ItemStartControls(
                placement: .inline, layout: .mainButtonPinned, preparing: Self.preparing, arrivalLine: Self.arrivalLine,
                choices: choices, onMainButton: {}, onSecondChoice: {})
            XCTAssertTrue(inline.drawsAnything, "\(label): nothing moved into the content")
            XCTAssertGreaterThan(Self.height(.inline, choices: choices, size: .accessibility5), 0, "\(label): the content part drew nothing")
        }
        let bare = ItemStartControls(
            placement: .inline, layout: .mainButtonPinned, preparing: nil, arrivalLine: nil,
            choices: Self.states[0].choices, onMainButton: {}, onSecondChoice: {})
        XCTAssertFalse(bare.drawsAnything, "a plain Continue with no status line leaves an empty stack in the content")
    }

    /// At the default and large sizes the pinned area is what it was: every part, and nothing in the content.
    func testNormalSizesKeepEveryPartPinned() {
        for size in [DynamicTypeSize.large, .xxxLarge] {
            for (label, choices) in Self.states {
                let full = Self.height(.pinned, choices: choices, size: size)
                let bare = Self.height(.pinned, choices: choices, size: size, preparing: nil, arrivalLine: nil)
                XCTAssertGreaterThan(full, bare, "\(label) at \(size): the status lines left the pinned area")
                let inline = ItemStartControls(
                    placement: .inline, layout: ItemStartControlsLayout(accessibilityTextSize: false),
                    preparing: Self.preparing, arrivalLine: Self.arrivalLine, choices: choices, onMainButton: {}, onSecondChoice: {})
                XCTAssertFalse(inline.drawsAnything, "\(label) at \(size): a part was drawn in the content too")
            }
        }
    }
}
