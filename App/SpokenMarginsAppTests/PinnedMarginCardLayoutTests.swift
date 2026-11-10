import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Verification of #3597's last Done-when item: the pinned Margin card is checked for each stage, at the default and at a
/// large Dynamic Type size (#1933). `PinnedMarginCardBody` is drawn with no model, one card per stage `PinnedMarginCard`
/// can produce, at the phone's 393 pt width. For each:
///
/// - every button's accessibility label is its action's title (the words and the buttons agree on screen too);
/// - the headline and the detail are not empty;
/// - the card stays under a height budget that leaves room for the rest of the Now screen;
/// - every button is whole inside the card, so a capped card never hides a button below its edge;
/// - every button is at least 44 pt tall.
///
/// SwiftUI vends its accessibility tree only when an assistive client runs, so the class turns accessibility automation
/// on first, as `AccessibilityFixProofTests` does. The test runs in a simulator only.
@MainActor
final class PinnedMarginCardLayoutTests: XCTestCase {
    private static let width: CGFloat = 393
    private static let windowHeight: CGFloat = 852
    /// The card sits above the title, the transport and the Auto-play row, which together need about half the 852 pt screen
    /// at the largest sizes it is meant to hold (the transport is two 44 pt rows with a scrubber, the Auto-play row about 60 pt,
    /// the title block and the safe areas the rest). So the card gets 200 pt at the default size, where it is one headline line,
    /// two detail lines and one 44 pt row (about 160 pt measured by hand, 40 pt of slack), and 430 pt (half the screen) at
    /// accessibility3, where the buttons stack and the words wrap. Uncapped, a long name there drew the card 920 pt tall
    /// (first lane run, 2026-11-10); the words now scroll inside `PinnedMarginCardBody.maxContentHeight`.
    private static let budgets: [(size: DynamicTypeSize, label: String, maxHeight: CGFloat)] = [
        (.large, "large", 200),
        (.accessibility3, "accessibility3", 430),
    ]
    private static let minimumTap: CGFloat = 44
    private static let longName = "Alexandria Bartholomew-Featherstonehaugh the Third"
    private static var automationWasEnabled: Int32?

    override class func setUp() {
        super.setUp()
        automationWasEnabled = AccessibilityAutomation.enable()
    }

    override class func tearDown() {
        if let automationWasEnabled { AccessibilityAutomation.set(automationWasEnabled) }
        super.tearDown()
    }

    /// Every stage, for the friend's Margin with a short name, for a long name, for a review and for the listener's own.
    private static func cards() -> [(name: String, card: PinnedMarginCard, isReview: Bool)] {
        let seek = NextMarginPress.seekToLeadIn(mediaTimeMs: 60_000)
        var found: [(String, PinnedMarginCard, Bool)] = []
        for (who, subject) in [("short", PinnedMarginCard.Subject.friend("Cole")), ("long", .friend(longName)), ("own", .yours)] {
            let stages: [(String, PinnedMarginCard.Stage, PinnedMarginCard.Run, NextMarginPress)] = [
                ("speaking", .speaking, .none, .unavailable),
                ("reading", .reading, .none, .unavailable),
                ("voicePaused", .voicePaused, .none, .unavailable),
                ("loading", .loading, .none, .unavailable),
                ("failed", .failed, .none, .unavailable),
                ("comingUp", .comingUp(msRemaining: 8_000), .none, .unavailable),
                ("waitingForTap", .waitingForTap, .none, .unavailable),
                ("upNext playsByItself", .upNext(msRemaining: 120_000, arrival: .playsByItself), .none, seek),
                ("upNext toneThenTap", .upNext(msRemaining: 120_000, arrival: .toneThenTap), .none, seek),
                ("upNext onRequest", .upNext(msRemaining: 120_000, arrival: .onRequest), .none, .playMarginNow),
                ("upNext announcedUnheard", .upNext(msRemaining: 120_000, arrival: .announcedUnheard), .none, .playMarginNow),
                ("upNext waitsForYou", .upNext(msRemaining: 120_000, arrival: .waitsForYou), .none, .playMarginNow),
                ("upNext no button", .upNext(msRemaining: nil, arrival: .playsByItself), .none, .unavailable),
                ("answerSaved", .answerSaved(atMs: 65_000, sentTo: "Cole"), .none, .unavailable),
                ("lastMargin", .lastMargin(senders: 1), .none, .unavailable),
                ("lastMargin many", .lastMargin(senders: 3), .none, .unavailable),
                ("moment comingUp", .comingUp(msRemaining: 8_000), .moment, .unavailable),
                ("review speaking", .speaking, .review, .skipVoice),
                ("review comingUp far", .comingUp(msRemaining: 8_000), .review, seek),
                ("review comingUp near", .comingUp(msRemaining: 8_000), .review, .playMarginNow),
            ]
            for (stageName, stage, run, press) in stages {
                let card = PinnedMarginCard(
                    subject: subject, stage: stage, position: "2 of 3", voiceTime: "0:14 of 0:41", noun: .episode,
                    nextPress: press, run: run)
                found.append(("\(who) \(stageName)", card, run == .review))
            }
        }
        return found
    }

    func testEveryStageHoldsItsWordsButtonsAndHeightAtDefaultAndLargeText() async throws {
        let cards = Self.cards()
        XCTAssertGreaterThan(cards.count, 40, "the stage table shrank")
        for (size, sizeLabel, maxHeight) in Self.budgets {
            for (name, card, isReview) in cards {
                let context = "\(name) at \(sizeLabel)"
                let detail = card.detail
                XCTAssertFalse(card.headline.isEmpty, "\(context): the headline is empty")
                XCTAssertFalse(detail.isEmpty, "\(context): the detail is empty")
                let body = PinnedMarginCardBody(
                    card: card, detail: detail, isReview: isReview, navigationLocked: false, perform: { _ in })
                let height = Self.height(of: body, size: size)
                XCTAssertLessThanOrEqual(height, maxHeight, "\(context): the card is \(height) pt tall; the budget is \(maxHeight) pt")

                let mounted = try mount(body, size: size)
                defer { mounted.close() }
                _ = try await mounted.waitForNode("\(context): the detail line") { $0.identifier == "marginCard.detail" }
                let buttons = mounted.nodes().filter { $0.traits.contains(.button) }
                    .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
                XCTAssertEqual(buttons.map { $0.label ?? "" }, card.actions.map(\.title),
                               "\(context): the buttons' labels differ from the actions' titles")
                for button in buttons {
                    // `mount` draws the card from the window's top, so the card spans 0 to `height`.
                    XCTAssertLessThanOrEqual(button.frame.maxY, height + 1,
                                             "\(context): \"\(button.label ?? "")\" ends at \(button.frame.maxY) pt, below the \(height) pt card")
                    XCTAssertGreaterThanOrEqual(button.frame.height, Self.minimumTap,
                                                "\(context): \"\(button.label ?? "")\" is \(button.frame.height) pt tall")
                    XCTAssertGreaterThanOrEqual(button.frame.width, Self.minimumTap,
                                                "\(context): \"\(button.label ?? "")\" is \(button.frame.width) pt wide")
                }
            }
        }
    }

    // MARK: - Drawing

    private static func height(of body: PinnedMarginCardBody, size: DynamicTypeSize) -> CGFloat {
        UIHostingController(rootView: body.environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: width, height: 4_000)).height
    }

    private func mount(_ body: PinnedMarginCardBody, size: DynamicTypeSize) throws -> MountedTree {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: AnyView(
            body.environment(\.dynamicTypeSize, size).frame(maxHeight: .infinity, alignment: .top)))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.windowHeight)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return MountedTree(window: window, previousKeyWindow: previousKeyWindow)
    }
}
