@testable import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Throwaway, never merged (PR #5408, #5334): draws the Share Margins review and preview steps at the head's code into
/// the test log as PNGs, so a session that may not boot a simulator can look at them. Each picture is printed as
/// base64 lines `SMSHOT <name> <i>/<n> <data>`, with `SMNODE` lines giving the frames of the controls.
@MainActor
final class ShareSheetLookTests: XCTestCase {
    private static let sizes: [(String, UIContentSizeCategory)] = [("default", .large), ("ax5", .accessibilityExtraExtraExtraLarge)]

    func testReplySheet() async throws {
        try await look(reply: true)
    }

    func testListSheet() async throws {
        try await look(reply: false)
    }

    private func look(reply: Bool) async throws {
        let was = AccessibilityAutomation.enable()
        defer { if let was { AccessibilityAutomation.set(was) } }
        let kind = reply ? "reply" : "list"
        for (sizeName, size) in Self.sizes {
            let model = try makeModel()
            let coordinator = Build23SharingCoordinator(model: model)
            if reply {
                model.presentReplyBackShare(ReplyBackOffer(replies: model.selectedItem.interjections, others: [], friendLabels: ["Cole"]))
            }
            let view = SheetHost {
                Build23SenderSharingExperience(coordinator: coordinator)
                    .environmentObject(model)
            }
            let mounted = try mount(AnyView(view), size: size)
            defer { mounted.close() }
            let name = "\(kind)-\(sizeName)"

            _ = try await mounted.waitForNode("\(name) review") { $0.identifier == "build23.sender.review.share" }
            if !reply {
                for margin in coordinator.snapshot.margins {
                    coordinator.send(.setIncluded(id: margin.id, included: true))
                }
            }
            coordinator.send(.setPrivateSharingRightsConfirmed(true))
            print("SMNODE \(name) stage=\(coordinator.snapshot.stage) showsList=\(coordinator.snapshot.showsList)")
            try await settle(mounted.window)
            try await pollUntil(timeout: .seconds(10)) {
                mounted.nodes().contains { $0.identifier == "build23.sender.review.share.file" }
            }
            try await settle(mounted.window)
            try await shots("\(name)-1-review", mounted)

            coordinator.send(.buildRecipientPreview)
            try await waitForSharingPreview(coordinator)
            XCTAssertEqual(coordinator.snapshot.previewState, .ready, "\(name): the preview never got ready")
            _ = try await mounted.waitForNode("\(name) preview") { $0.identifier == "build23.sender.share.present" }
            try await settle(mounted.window)
            try await shots("\(name)-2-preview", mounted)
        }
    }

    /// The screen as it opens, then scrolled to the end, then to the top.
    private func shots(_ name: String, _ mounted: MountedTree) async throws {
        dumpNodes(name, mounted)
        shot("\(name)-a-open", mounted.window)
        guard let scroll = verticalScrollViews(in: top(mounted.window).view).first else {
            return print("SMNODE \(name) no scroll view scrolls")
        }
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        try await settle(mounted.window)
        dumpNodes("\(name)-end", mounted)
        shot("\(name)-b-end", mounted.window)
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        try await settle(mounted.window)
        dumpNodes("\(name)-top", mounted)
        shot("\(name)-c-top", mounted.window)
        let backIDs: Set<String> = ["build23.sender.review.back", "build23.sender.preview.edit"]
        guard let back = mounted.nodes().first(where: { backIDs.contains($0.identifier ?? "") }) else {
            return print("SMNODE \(name) no back button")
        }
        // Put the back button's top 110 pt below the sheet's top, where the strip above the pinned bar shows it.
        let sheetTop = top(mounted.window).view.convert(CGPoint.zero, to: nil).y
        let offset = scroll.contentOffset.y + back.frame.minY - (sheetTop + 110)
        scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, offset)), animated: false)
        try await settle(mounted.window)
        dumpNodes("\(name)-back", mounted)
        shot("\(name)-d-back", mounted.window)
    }

    // MARK: - Fixtures

    private func makeModel() throws -> Gate1AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appending(path: "library.sqlite"))
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        let words = [
            "This is the part where the argument turns, and I think it is worth hearing twice.",
            "I disagree with this a little: the evidence here is one study, and a small one.",
        ]
        model.selectedItem.interjections = words.enumerated().map { index, transcript in
            Interjection(
                id: "margin-look-\(index)", itemId: itemID, sessionId: "session-look", targetType: .item, targetId: itemID,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1)), roughPercent: (index + 1) * 20,
                anchor: Anchor(anchorType: .text, startChar: index * 5, endChar: index * 5 + 5,
                               anchorBefore: "Before \(index)", anchorAfter: "After \(index)"),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: transcript,
                cleanedTranscript: nil, displayText: nil, status: "active")
        }
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

    private func dumpNodes(_ name: String, _ mounted: MountedTree) {
        print("SMNODE \(name) window=\(mounted.window.bounds) sheet=\(top(mounted.window).view.frame)")
        for node in mounted.nodes() where (node.identifier ?? "").hasPrefix("build23.sender.") {
            print("SMNODE \(name) \(node.identifier ?? "") \"\(node.label ?? "")\" \(node.frame)")
        }
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

/// A plain screen behind, with the sheet presented over it once it appears, as the app presents Share Margins.
private struct SheetHost<Sheet: View>: View {
    @ViewBuilder let sheet: () -> Sheet
    @State private var shown = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Now Playing (behind the sheet)").font(.title)
            Spacer()
        }
        .padding(.top, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $shown) { sheet() }
        .onAppear { shown = true }
    }
}
