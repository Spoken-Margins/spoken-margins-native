import SessionKit
import SessionKitSharing
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Throwaway, never merged (#5268, PR #5300): draws the three sharing screens that PR changed into the test log as
/// PNGs, so a session that may not boot a simulator can look at them. Each picture is printed as base64 lines
/// `SMSHOT <name> <i>/<n> <data>`, with `SMNODE` lines giving the frames of the controls.
@MainActor
final class FriendHelpLookTests: XCTestCase {
    private static let sizes: [(String, UIContentSizeCategory)] = [("default", .large), ("ax5", .accessibilityExtraExtraExtraLarge)]

    func testOpenFailureSheet() async throws {
        let was = AccessibilityAutomation.enable()
        defer { if let was { AccessibilityAutomation.set(was) } }
        let rows: [(String, PacketOpenFailureSheetContent, Bool)] = [
            ("offline", PacketOpenFailureSheetContent(row: .offline), true),
            ("cutoff", PacketOpenFailureSheetContent(row: .cutOff, reportLinkID: String(repeating: "ab12", count: 8)), false),
        ]
        for (rowName, content, retry) in rows {
            for (sizeName, size) in Self.sizes {
                let name = "fail-\(rowName)-\(sizeName)"
                let sheet = PacketOpenFailureSheet(content: content, showsTryAgain: retry, isRetrying: false, tryAgain: {}, close: {})
                let mounted = try mount(AnyView(SheetHost { sheet }), size: size)
                defer { mounted.close() }
                try await lookThrough(name, mounted, sheetID: "packetOpenFailure.sheet", helpID: "packetOpenFailure.help",
                                      prefix: "packetOpenFailure.")
            }
        }
    }

    func testImportSheetMissingSourceNotice() async throws {
        let was = AccessibilityAutomation.enable()
        defer { if let was { AccessibilityAutomation.set(was) } }
        let model = try await makeMissingSourceModel()
        let coordinator = Build23SharingCoordinator(model: model)
        for (sizeName, size) in Self.sizes {
            let view = SheetHost {
                Build23RecipientSharingExperience(coordinator: coordinator, onRequestMissingSource: { _ in })
                    .interactiveDismissDisabled()
            }
            let mounted = try mount(AnyView(view), size: size)
            defer { mounted.close() }
            try await lookThrough("import-\(sizeName)", mounted, sheetID: "build23.recipient.help", helpID: "build23.recipient.help",
                                  prefix: "build23.recipient.")
        }
    }

    func testItemScreenDownloadFailedRow() async throws {
        let was = AccessibilityAutomation.enable()
        defer { if let was { AccessibilityAutomation.set(was) } }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let date = Date(timeIntervalSince1970: 1_777_000_000)
        let identity = SharedItemIdentity(itemType: .podcast, title: "Episode 12: The Harbour", showTitle: "Harbour Show")
        var item = ItemDetailState()
        item.id = "item"
        item.title = "Episode 12: The Harbour"
        item.importedCommentaryLayers = [ImportedCommentaryLayer(
            id: "ben", packageDigest: String(repeating: "b", count: 64), packageId: "ben", itemIdentity: identity,
            displayLabel: "Ben", importedAt: date)]
        model.selectedItem = item
        model.podcastDownloadRecords[item.id] = PodcastDownloadRecord(
            id: "d", itemId: item.id, remoteURL: "https://example.com/a.mp3", state: .failed, updatedAt: date,
            failureReason: "The server refused the download.")
        let coordinator = Build23SharingCoordinator(model: model)
        XCTAssertFalse(coordinator.importedLayers.isEmpty)
        for (sizeName, size) in Self.sizes {
            let view = NavigationStack { ExperienceItemDetailScreen() }
                .environmentObject(model)
                .environmentObject(coordinator)
            let mounted = try mount(AnyView(view), size: size)
            defer { mounted.close() }
            let name = "item-\(sizeName)"
            let help = try await mounted.waitForNode("item help") { $0.identifier == "item.podcastDownload.help" }
            scrollIntoView(help.frame, in: mounted.window)
            try await settle(mounted.window)
            dumpNodes(name, mounted) { ($0.identifier ?? "").hasPrefix("item.podcastDownload") }
            shot("\(name)-1-screen", mounted.window)
            XCTAssertTrue(mounted.activate { $0.identifier == "item.podcastDownload.help" }, "\(name): Get Help did not activate")
            try await helpThenDone(name, mounted)
            XCTAssertNotNil(mounted.nodes().first { $0.identifier == "item.podcastDownload.help" }, "\(name): the row is gone after Done")
        }
    }

    // MARK: - Steps

    private func lookThrough(_ name: String, _ mounted: MountedTree, sheetID: String, helpID: String, prefix: String) async throws {
        _ = try await mounted.waitForNode("\(name) sheet") { $0.identifier == sheetID }
        try await settle(mounted.window)
        dumpNodes(name, mounted) { ($0.identifier ?? "").hasPrefix(prefix) }
        shot("\(name)-1-sheet", mounted.window)
        if let scroll = verticalScrollViews(in: top(mounted.window).view).first {
            let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            try await settle(mounted.window)
            dumpNodes("\(name)-scrolled", mounted) { ($0.identifier ?? "").hasPrefix(prefix) }
            shot("\(name)-2-scrolled-to-end", mounted.window)
        }
        XCTAssertTrue(mounted.activate { $0.identifier == helpID }, "\(name): Get Help did not activate")
        try await helpThenDone(name, mounted)
        XCTAssertNotNil(mounted.nodes().first { $0.identifier == helpID }, "\(name): Get Help is gone after Done")
    }

    private func helpThenDone(_ name: String, _ mounted: MountedTree) async throws {
        _ = try await mounted.waitForNode("\(name) help") { $0.identifier == "friendHelp.done" }
        try await settle(mounted.window)
        shot("\(name)-3-help", mounted.window)
        let depth = chain(mounted.window).count
        XCTAssertTrue(mounted.activate { $0.identifier == "friendHelp.done" }, "\(name): Done did not activate")
        try await pollUntil(timeout: .seconds(10)) { chain(mounted.window).count == depth - 1 }
        try await settle(mounted.window)
        shot("\(name)-4-after-done", mounted.window)
    }

    // MARK: - Fixtures

    /// A recipient whose Library lacks the article, with a recipient-supplied text packet open for import, as
    /// SourceLinkImportTests.makePrivateFeedFixture builds one for a podcast.
    private func makeMissingSourceModel() async throws -> Gate1AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "library.sqlite")
        let packageURL = root.appending(path: "friend.spokenmargins")
        let created = Date(timeIntervalSince1970: 1_777_000_000)
        let revision = InterjectionShareRevision(
            id: "revision", interjectionId: "margin", itemId: "sender", sessionId: "sender-session", createdAt: created,
            approvedTranscript: "A thought on the harbour.", anchorBefore: "", anchorAfter: "", status: .senderApproved)
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "friend-help-look",
            createdAt: created,
            item: SharedItemIdentity(itemType: .text, title: "Harbour Lights"),
            itemTransportSelection: .recipientSupplied,
            selections: [ReviewedInterjectionSelection(
                packageScopedId: "margin-001", revision: revision,
                anchor: PortableAnchorEvidence(anchorType: .text), representation: .textOnly)],
            senderDisplayLabel: "Ana"
        )
        _ = try SpokenMarginsPackageArchive.write(prepared, to: packageURL)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        model.handleIncomingURL(packageURL)
        await model.waitForPackageStaging()
        return model
    }

    // MARK: - Drawing

    private func mount(_ view: AnyView, size: UIContentSizeCategory) throws -> MountedTree {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.traitOverrides.preferredContentSizeCategory = size
        window.rootViewController = UIHostingController(rootView: view.environment(\.dynamicTypeSize, DynamicTypeSize(size) ?? .large))
        window.makeKeyAndVisible()
        return MountedTree(window: window, previousKeyWindow: previousKeyWindow)
    }

    /// Waits for every presentation to finish moving, then one more run loop for the last frame.
    private func settle(_ window: UIWindow) async throws {
        try await pollUntil(timeout: .seconds(10)) {
            chain(window).allSatisfy { !$0.isBeingPresented && !$0.isBeingDismissed && $0.transitionCoordinator == nil }
        }
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
    }

    private func shot(_ name: String, _ window: UIWindow) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData()?.base64EncodedString() else { return XCTFail("\(name): no PNG") }
        let chunk = 8000
        let count = (data.count + chunk - 1) / chunk
        var start = data.startIndex
        for index in 1...count {
            let end = data.index(start, offsetBy: chunk, limitedBy: data.endIndex) ?? data.endIndex
            print("SMSHOT \(name) \(index)/\(count) \(data[start..<end])")
            start = end
        }
    }

    private func dumpNodes(_ name: String, _ mounted: MountedTree, _ include: (AccessibilityNode) -> Bool) {
        print("SMNODE \(name) window=\(mounted.window.bounds) sheet=\(top(mounted.window).view.frame)")
        for node in mounted.nodes() where include(node) {
            print("SMNODE \(name) \(node.identifier ?? "") \"\(node.label ?? "")\" \(node.frame)")
        }
    }

    private func scrollIntoView(_ frame: CGRect, in window: UIWindow) {
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let scroll = verticalScrollViews(in: window).first(where: {
            $0.convert(CGRect(origin: .zero, size: $0.contentSize), to: nil).contains(point)
        }) else { return print("SMNODE no scroll view holds \(frame)") }
        scroll.scrollRectToVisible(scroll.convert(frame, from: nil).insetBy(dx: 0, dy: -120), animated: false)
    }

    /// The scroll views that scroll vertically, largest first.
    private func verticalScrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled, scroll.contentSize.height > scroll.bounds.height + 1 {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
    }
}

@MainActor
private func chain(_ window: UIWindow) -> [UIViewController] {
    var found: [UIViewController] = []
    var next = window.rootViewController
    while let controller = next {
        found.append(controller)
        next = controller.presentedViewController
    }
    return found
}

@MainActor
private func top(_ window: UIWindow) -> UIViewController {
    chain(window).last ?? UIViewController()
}

/// A plain screen behind, with the sheet presented over it once it appears, as the app presents these.
private struct SheetHost<Sheet: View>: View {
    @ViewBuilder let sheet: () -> Sheet
    @State private var shown = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Library (behind the sheet)").font(.title)
            Spacer()
        }
        .padding(.top, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $shown) { sheet() }
        .onAppear { shown = true }
    }
}
