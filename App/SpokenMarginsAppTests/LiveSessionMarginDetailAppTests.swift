import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// The live session's Margin screen (#3491): the words, hear the recording, edit, delete, and nothing for sharing.
/// Mounted in a window and read through the accessibility tree, as `AccessibilityFixProofTests` does.
@MainActor
final class LiveSessionMarginDetailAppTests: XCTestCase {
    private static var automationWasEnabled: Int32?

    override class func setUp() {
        super.setUp()
        automationWasEnabled = AccessibilityAutomation.enable()
    }

    override class func tearDown() {
        if let automationWasEnabled { AccessibilityAutomation.set(automationWasEnabled) }
        super.tearDown()
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func written() -> LiveSessionMargin {
        LiveSessionMargin(id: "w", text: "Ask about the budget", markedAt: now, sessionOffsetMs: 65_000)
    }

    private func spoken() -> LiveSessionMargin {
        LiveSessionMargin(id: "s", text: "Remember this part", markedAt: now, sessionOffsetMs: 10_000,
                          audioPath: "SpokenMargins/interjections/s.m4a", durationMs: 4_000, spokenOn: "phone")
    }

    private func blindMark() -> LiveSessionMargin {
        LiveSessionMargin(id: "b", text: "", markedAt: now, sessionOffsetMs: 2_000, isBlindMark: true)
    }

    private func mount(
        _ margin: LiveSessionMargin, photoPage: LiveSessionPlace? = nil,
        keepHeardPlace: @escaping () -> Void = {}, declineHeardPlace: @escaping () -> Void = {}
    ) throws -> MountedTree {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let view = LiveSessionMarginDetailView(
            margin: margin, sessionTitle: "Staff meeting", position: "1:05 in", photoPage: photoPage,
            keepHeardPlace: keepHeardPlace, declineHeardPlace: declineHeardPlace, saveText: { _ in }, delete: {})
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return MountedTree(window: window, previousKeyWindow: previous)
    }

    func testAWrittenMarginShowsItsWordsAndNeverStarOrShare() async throws {
        let tree = try mount(written())
        defer { tree.close() }
        _ = try await tree.waitForNode("the screen") { $0.identifier == "marginDetail.screen" }
        _ = try await tree.waitForNode("the words") { $0.label == "Ask about the budget" }
        _ = try await tree.waitForNode("the kind line") { $0.label == "Written Margin · Staff meeting" }
        _ = try await tree.waitForNode("Edit") { $0.identifier == "marginDetail.edit.button" }
        _ = try await tree.waitForNode("Delete") { $0.identifier == "marginDetail.delete.button" }
        let ids = Set(tree.nodes().compactMap(\.identifier))
        XCTAssertFalse(ids.contains("marginDetail.star.button"))
        XCTAssertFalse(ids.contains("marginDetail.shareMarkdown.button"))
        XCTAssertFalse(ids.contains("marginDetail.more.button"))
        XCTAssertFalse(ids.contains("marginDetail.playMoment.button"))
        XCTAssertFalse(ids.contains("marginDetail.playRecording.button"), "A written Margin has no recording to hear")
    }

    /// #2708: a page number read from the photo is offered the way a page heard in the words is, with Keep and No.
    func testAPageReadFromAPhotoIsOfferedWithKeepAndNo() async throws {
        var kept = 0
        var declined = 0
        let tree = try mount(written(), photoPage: LiveSessionPlace(unit: .page, value: 118),
                             keepHeardPlace: { kept += 1 }, declineHeardPlace: { declined += 1 })
        defer { tree.close() }
        _ = try await tree.waitForNode("the offer") {
            $0.identifier == "marginDetail.photoPage.label" && $0.label == "Read \u{201C}118\u{201D} on the page. Keep it as a checkpoint?"
        }
        _ = try await tree.waitForNode("No") { $0.identifier == "marginDetail.declinePhotoPage.button" }
        XCTAssertEqual(kept + declined, 0, "Mounting keeps and turns down nothing")
        XCTAssertTrue(tree.activate { $0.identifier == "marginDetail.keepPhotoPage.button" }, "Keep refused the activation")
        XCTAssertEqual(kept, 1)
        XCTAssertEqual(declined, 0)
    }

    func testNoOfferShowsWhenNoPageWasRead() async throws {
        let tree = try mount(written())
        defer { tree.close() }
        _ = try await tree.waitForNode("the screen") { $0.identifier == "marginDetail.screen" }
        XCTAssertFalse(tree.nodes().contains { $0.identifier == "marginDetail.photoPage.label" })
    }

    func testASpokenMarginOffersTheRecording() async throws {
        let tree = try mount(spoken())
        defer { tree.close() }
        _ = try await tree.waitForNode("Hear my recording") { $0.identifier == "marginDetail.playRecording.button" }
        _ = try await tree.waitForNode("the kind line") { $0.label == "Spoken Margin · Staff meeting" }
        XCTAssertFalse(tree.nodes().contains { $0.identifier == "marginDetail.star.button" })
    }

    func testABlindMarkIsNamedAMarkAndHasNoRecording() async throws {
        let tree = try mount(blindMark())
        defer { tree.close() }
        _ = try await tree.waitForNode("the kind line") { $0.label == "Mark · Staff meeting" }
        XCTAssertFalse(tree.nodes().contains { $0.identifier == "marginDetail.playRecording.button" })
    }

    /// #4311: the confirmation is absent until presented, so only tapping Delete can show that it asks first.
    func testDeleteAsksBeforeDeleting() async throws {
        var deleted = 0
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let view = LiveSessionMarginDetailView(
            margin: written(), sessionTitle: "Staff meeting", position: "1:05 in",
            keepHeardPlace: {}, declineHeardPlace: {}, saveText: { _ in }, delete: { deleted += 1 })
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        let tree = MountedTree(window: window, previousKeyWindow: previous)
        defer {
            host.dismiss(animated: false) // an alert still up after a failure goes with the window
            tree.close()
        }
        _ = try await tree.waitForNode("Delete") { $0.identifier == "marginDetail.delete.button" }
        XCTAssertEqual(deleted, 0, "Mounting must not delete")
        let isConfirm: (AccessibilityNode) -> Bool = {
            $0.identifier == "marginDetail.delete.confirm.button" || $0.label == "Delete Margin"
        }
        XCTAssertFalse(tree.nodes().contains(where: isConfirm), "The confirmation is shown only after Delete is tapped")

        XCTAssertTrue(tree.activate { $0.identifier == "marginDetail.delete.button" }, "Delete refused the activation")
        XCTAssertEqual(deleted, 0, "Delete asks first; it deletes nothing until the listener confirms")
        _ = try await tree.waitForNode("the Delete Margin confirmation", isConfirm)
        XCTAssertEqual(deleted, 0, "the confirmation is up and nothing is deleted yet")

        if !tree.activate(isConfirm) {
            // An alert's action can refuse an in-process activation (VoiceOver then taps it); run the action as the tap would.
            let alert = try XCTUnwrap(host.presentedViewController as? UIAlertController,
                                      "the confirmation refused the activation and is not an alert")
            try Self.tap("Delete Margin", in: alert)
        }
        try await pollUntil { deleted > 0 }
        XCTAssertEqual(deleted, 1, "Delete Margin deletes, once")
    }

    /// #5304: on main 282b4c8 the row was a `NavigationLink` with a simultaneous tap gesture under the screen's primitive
    /// button style, and tapping it never pushed the move sheet. Activating Move must push "Moving this Margin", with no
    /// Choose…, for a written and a spoken Margin.
    func testMoveToAnItemPushesTheMoveSheetForThisMargin() async throws {
        for margin in [written(), spoken()] {
            let session = LiveSession(id: "live-1", title: "Staff meeting", startedAt: now, margins: [margin])
            var made = 0
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first { $0.isKeyWindow }
            let view = LiveSessionMarginDetailView(
                margin: margin, sessionTitle: "Staff meeting", position: "1:05 in",
                keepHeardPlace: {}, declineHeardPlace: {}, saveText: { _ in }, delete: {},
                makeMove: {
                    made += 1
                    return LiveMarginMoveSheetModel(
                        session: session, marginIds: [margin.id], loadChoices: { [] },
                        makePlan: { _, _ in throw SessionKitError.persistenceFailed("not moved in this test") })
                })
            let host = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            window.makeKeyAndVisible()
            let tree = MountedTree(window: window, previousKeyWindow: previous)
            defer { tree.close() }
            _ = try await tree.waitForNode("Move to an Item… (\(margin.id))") { $0.identifier == "marginDetail.move.button" }
            XCTAssertFalse(tree.nodes().contains { $0.identifier == "liveMove.screen" }, "the move sheet waits for the tap")
            XCTAssertTrue(tree.activate { $0.identifier == "marginDetail.move.button" }, "Move refused the activation")
            _ = try await tree.waitForNode("Moving this Margin (\(margin.id))") {
                $0.identifier == "liveMove.moving.label" && $0.label == "Moving this Margin"
            }
            XCTAssertFalse(tree.nodes().contains { $0.identifier == "liveMove.choose.button" }, "one Margin has no Choose…")
            XCTAssertEqual(made, 1, "the move sheet's state is made once, for this Margin")
        }
    }

    private static func tap(_ title: String, in alert: UIAlertController) throws {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let action = try XCTUnwrap(alert.actions.first { $0.title == title }, "no \(title) in \(alert.actions.compactMap(\.title))")
        let block = try XCTUnwrap(action.value(forKey: "handler") as AnyObject?, "\(title) has no handler")
        unsafeBitCast(block, to: Handler.self)(action)
    }

    func testAudioModelSaysSoWhenTheRecordingIsMissing() async throws {
        let model = LiveSessionMarginAudioModel()
        var paused = 0
        model.toggle(audioPath: "SpokenMargins/interjections/not-there.m4a", prepare: { paused += 1 })
        XCTAssertEqual(paused, 1, "Starting pauses whatever else is playing")
        XCTAssertTrue(model.isPlaying, "The button shows playing at once")
        try await pollUntil { model.message != nil }
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.isPlaying)
    }

    /// The audit on 17f2ffa: the Margins pane shares one model across its rows. A tap on B while A plays stopped A
    /// and started nothing, and every row said "Stop playing" while A played.
    func testATapOnAnotherMarginMovesPlaybackToIt() async throws {
        let model = LiveSessionMarginAudioModel()
        var paused = 0
        model.toggle(id: "a", audioPath: "SpokenMargins/interjections/not-there-a.m4a", prepare: { paused += 1 })
        XCTAssertEqual(model.playingId, "a")
        model.toggle(id: "b", audioPath: "SpokenMargins/interjections/not-there-b.m4a", prepare: { paused += 1 })
        XCTAssertEqual(model.playingId, "b", "B plays; the tap doesn't just stop A")
        XCTAssertEqual(paused, 2)
        model.toggle(id: "b", audioPath: "SpokenMargins/interjections/not-there-b.m4a", prepare: { paused += 1 })
        XCTAssertNil(model.playingId, "a second tap on the playing Margin stops it")
        XCTAssertEqual(paused, 2, "stopping pauses nothing")
    }
}
