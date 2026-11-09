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

    private func mount(_ margin: LiveSessionMargin) throws -> MountedTree {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let view = LiveSessionMarginDetailView(
            margin: margin, sessionTitle: "Staff meeting", position: "1:05 in",
            keepHeardPlace: {}, declineHeardPlace: {}, saveText: { _ in }, delete: {})
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

    func testDeleteAsksBeforeDeleting() async throws {
        var deleted = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let view = LiveSessionMarginDetailView(
            margin: written(), sessionTitle: "Staff meeting", position: "1:05 in",
            keepHeardPlace: {}, declineHeardPlace: {}, saveText: { _ in }, delete: { deleted = true })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        let tree = MountedTree(window: window, previousKeyWindow: previous)
        defer { tree.close() }
        _ = try await tree.waitForNode("Delete") { $0.identifier == "marginDetail.delete.button" }
        XCTAssertFalse(deleted, "Mounting must not delete")
        XCTAssertFalse(tree.nodes().contains { $0.identifier == "marginDetail.delete.confirm.button" },
                       "The confirmation is shown only after Delete is tapped")
    }

    func testAudioModelSaysSoWhenTheRecordingIsMissing() async throws {
        let model = LiveSessionMarginAudioModel()
        var paused = 0
        model.toggle(audioPath: "SpokenMargins/interjections/not-there.m4a", prepare: { paused += 1 })
        XCTAssertEqual(paused, 1, "Starting pauses whatever else is playing")
        XCTAssertTrue(model.isPlaying, "The button shows playing at once")
        for _ in 0..<100 where model.message == nil { try await Task.sleep(for: .milliseconds(50)) }
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
