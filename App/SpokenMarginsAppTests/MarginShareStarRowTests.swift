import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #4173 PR 3: the sharing star on the listener's own Margin rows on the playback screen. Mounted rows, read through the
/// accessibility tree (the helpers and the automation switch are those of `AccessibilityFixProofTests`).
@MainActor
final class MarginShareStarRowTests: XCTestCase {
    private static var automationWasEnabled: Int32?

    override class func setUp() {
        super.setUp()
        automationWasEnabled = AccessibilityAutomation.enable()
    }

    override class func tearDown() {
        if let automationWasEnabled { AccessibilityAutomation.set(automationWasEnabled) }
        super.tearDown()
    }

    func testAnOwnRowExposesTheStarAsAToggleWithItsWordsAndATapTarget() async throws {
        let row = try mount(rowView(star: .init(isStarred: false, action: {})))
        defer { row.close() }
        let star = try await row.waitForNode("the star") { $0.identifier == "margins.row.x.star" }
        XCTAssertEqual(star.label, "Star for sharing: A Margin worth sending")
        XCTAssertTrue(star.traits.contains(.toggleButton), "traits \(star.traits.rawValue)")
        XCTAssertAtLeastPoints(star.frame.height, TapTarget.minimum, "the star is \(star.frame.height) pt tall")
        XCTAssertAtLeastPoints(star.frame.width, TapTarget.minimum, "the star is \(star.frame.width) pt wide")
    }

    func testARowWithNoStarShowsNone() async throws {
        let row = try mount(rowView(star: nil))
        defer { row.close() }
        _ = try await row.waitForNode("the play button") { $0.identifier == "margins.row.x.play" }
        XCTAssertFalse(row.nodes().contains { $0.identifier?.hasSuffix(".star") == true }, "a row with no star shows one")
    }

    func testAStarredRowSaysStarredInWordsAndTheStarIsTappable() async throws {
        var taps = 0
        let row = try mount(rowView(star: .init(isStarred: true, action: { taps += 1 })))
        defer { row.close() }
        let details = try await row.waitForNode("the row's details button") { $0.identifier == "margins.row.x" }
        XCTAssertTrue(details.label?.contains("Starred") == true, "the details read \(details.label ?? "nil")")
        XCTAssertTrue(row.activate { $0.identifier == "margins.row.x.star" })
        XCTAssertEqual(taps, 1)
    }

    func testAnUnstarredRowDoesNotSayStarred() async throws {
        let row = try mount(rowView(star: .init(isStarred: false, action: {})))
        defer { row.close() }
        let details = try await row.waitForNode("the row's details button") { $0.identifier == "margins.row.x" }
        XCTAssertFalse(details.label?.contains("Starred") == true, "the details read \(details.label ?? "nil")")
        XCTAssertTrue(details.label?.contains("My Margin") == true)
    }

    /// A friend's row has no star parameter at all: it reads exactly as before.
    func testAFriendsRowHasNoStar() async throws {
        let row = try mount(AnyView(PlaybackMarginRowView(title: "From Sam", detail: "00:01", isShared: true, identifier: "margins.shared.row.x",
                                                          showDetails: {}, play: {})))
        defer { row.close() }
        _ = try await row.waitForNode("the play button") { $0.identifier == "margins.shared.row.x.play" }
        XCTAssertFalse(row.nodes().contains { $0.identifier?.hasSuffix(".star") == true })
    }

    /// At accessibility5 the details take the full width and the star sits under them, beside Play.
    func testAtTheLargestTextSizeTheStarSitsUnderTheWords() async throws {
        let row = try mount(rowView(star: .init(isStarred: false, action: {})), textSize: .accessibility5)
        defer { row.close() }
        let details = try await row.waitForNode("the row's details button") { $0.identifier == "margins.row.x" }
        let star = try await row.waitForNode("the star") { $0.identifier == "margins.row.x.star" }
        let play = try await row.waitForNode("the play button") { $0.identifier == "margins.row.x.play" }
        XCTAssertGreaterThanOrEqual(star.frame.minY, details.frame.maxY - 1, "the star (\(star.frame)) is not under the words (\(details.frame))")
        XCTAssertGreaterThanOrEqual(play.frame.minY, details.frame.maxY - 1)
        XCTAssertLessThan(star.frame.maxX, play.frame.minX + 1, "the star and Play share a line, the star first")
    }

    /// A friend's row has no star, so it keeps Play on the trailing edge at every text size.
    func testAFriendsRowKeepsPlayBesideTheWordsAtTheLargestSize() async throws {
        let row = try mount(AnyView(PlaybackMarginRowView(title: "From Sam", detail: "00:01", isShared: true, identifier: "margins.shared.row.x",
                                                          showDetails: {}, play: {})), textSize: .accessibility5)
        defer { row.close() }
        let details = try await row.waitForNode("the details button") { $0.identifier == "margins.shared.row.x" }
        let play = try await row.waitForNode("the play button") { $0.identifier == "margins.shared.row.x.play" }
        XCTAssertGreaterThan(play.frame.minX, details.frame.maxX - 1, "Play (\(play.frame)) moved from beside the words (\(details.frame))")
    }

    func testTheSpokenTitleIsCutAtSixtyCharacters() {
        let long = String(repeating: "a", count: 90)
        XCTAssertEqual(MarginShareStarButton.accessibilityLabel(title: long), "Star for sharing: " + String(repeating: "a", count: 60))
        XCTAssertEqual(MarginShareStarButton.accessibilityLabel(title: "  short \n"), "Star for sharing: short")
        XCTAssertEqual(MarginShareStarButton.accessibilityValue(isStarred: true), "Starred")
        XCTAssertEqual(MarginShareStarButton.accessibilityValue(isStarred: false), "Not starred")
    }

    // MARK: -

    private func rowView(star: PlaybackMarginRowView.Star?) -> AnyView {
        AnyView(PlaybackMarginRowView(title: "A Margin worth sending", detail: "00:01", isShared: false, identifier: "margins.row.x",
                                      star: star, showDetails: {}, play: {}))
    }

    private func mount(_ view: AnyView, textSize: DynamicTypeSize = .large, width: CGFloat = 390) throws -> MountedTree {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: AnyView(view.environment(\.dynamicTypeSize, textSize)))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return MountedTree(window: window, previousKeyWindow: previousKeyWindow)
    }
}
