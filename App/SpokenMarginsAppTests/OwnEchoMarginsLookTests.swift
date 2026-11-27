@testable import SessionKit
@testable import SessionKitPersistence
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Throwaway, never merged (#4910): draws the Margins tab, All and Shared, for an item holding three of the listener's
/// own shared Margins, a packet of their copies imported back (from "Cole"), and Ben's two Margins. Each picture is
/// printed into the test log as base64 lines `SMSHOT <name> <i>/<n> <data>`, with `SMNODE` lines for the labels.
@MainActor
final class OwnEchoMarginsLookTests: XCTestCase {
    func testMarginsTab() async throws {
        let was = AccessibilityAutomation.enable()
        defer { if let was { AccessibilityAutomation.set(was) } }
        let model = try makeModel()
        print("SMNODE rows private=\(model.visiblePrivateMarginRows.count) shared=\(model.sharedMarginRows.count) ids=\(model.sharedMarginRows.map(\.interjection.id))")
        for filter in [MarginCollectionFilter.all, .shared] {
            model.marginCollectionQuery.filter = filter
            let mounted = try mount(AnyView(NavigationStack { ExperienceMarginsScreen(model: model) }))
            defer { mounted.close() }
            _ = try await mounted.waitForNode("filter \(filter)") { $0.identifier == "margins.filter.shared" }
            try await Task.sleep(for: .milliseconds(1500))
            mounted.window.layoutIfNeeded()
            let name = "margins-\(filter.rawValue)"
            for node in mounted.nodes() where !(node.label ?? "").isEmpty {
                print("SMNODE \(name) \(node.identifier ?? "-") \"\(node.label ?? "")\" \(node.frame)")
            }
            shot(name, mounted.window)
        }
    }

    private func makeModel() throws -> Gate1AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appending(path: "library.sqlite"))
        model.resetAndSeed()
        let store = try XCTUnwrap(model.store)
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        try store.saveItem(Item(id: "look-item", title: "The Listening Episode", mediaType: "text", text: "Words.", externalReference: nil, status: "ready"))
        try store.saveSession(Session(
            id: "look-session", itemId: "look-item", createdAt: when, updatedAt: when, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: "look-item", position: Position(), completionPercent: 0, playbackRate: 1))
        let mine = ["My own note about the opening.", "My second thought, on the interview.", "My third, near the end."]
        for (index, words) in mine.enumerated() {
            try store.saveInterjection(Interjection(
                id: "mine-\(index)", itemId: "look-item", sessionId: "look-session", targetType: .item, targetId: "look-item",
                createdAt: when.addingTimeInterval(Double(index)), roughPercent: (index + 1) * 20,
                anchor: Anchor(anchorType: .text, startChar: index * 5, endChar: index * 5 + 5, anchorBefore: "", anchorAfter: ""),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: words, cleanedTranscript: nil,
                displayText: nil, status: "active",
                sharedAs: [MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "m-\(index)")]))
        }
        func layer(_ id: String, digest: String, label: String) -> ImportedCommentaryLayer {
            ImportedCommentaryLayer(
                id: id, itemId: "look-item", packageDigest: digest, packageId: "package-\(id)",
                itemIdentity: SharedItemIdentity(itemType: .text, title: "The Listening Episode", durationMs: nil),
                displayLabel: label, importedAt: when, sourceResolutionStatus: .resolved, isEnabled: true)
        }
        func margin(_ id: String, layer: String, scoped: String, words: String, at: Int) -> ImportedCommentaryInterjection {
            ImportedCommentaryInterjection(
                id: id, layerId: layer, packageScopedId: scoped, createdAt: when.addingTimeInterval(Double(100 + at)),
                anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: words)
        }
        _ = try store.importCommentaryLayer(
            layer("echo", digest: "digest-mine", label: "Cole"),
            interjections: mine.enumerated().map { margin("copy-\($0.offset)", layer: "echo", scoped: "m-\($0.offset)", words: $0.element, at: $0.offset) })
        _ = try store.importCommentaryLayer(
            layer("ben", digest: "digest-ben", label: "Ben"),
            interjections: [margin("ben-0", layer: "ben", scoped: "b-0", words: "Ben: this part made me laugh.", at: 10),
                            margin("ben-1", layer: "ben", scoped: "b-1", words: "Ben: I'd push back on this claim.", at: 11)])
        model.refreshMarginRows()
        return model
    }

    private func mount(_ view: AnyView) throws -> MountedTree {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return MountedTree(window: window, previousKeyWindow: previousKeyWindow)
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
}
