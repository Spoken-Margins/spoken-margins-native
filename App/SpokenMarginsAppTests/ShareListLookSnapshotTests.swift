import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// THROWAWAY (#5180, do not merge): draws the Share Margins sheet in the simulator at each state the PR's look check
/// names, and prints each picture as base64 JPEG pages into the test log, so a session with no simulator of its own can
/// look at it through branch-t3's log artifact.
@MainActor
final class ShareListLookSnapshotTests: XCTestCase {
    private var priorEnabled: Any?
    private var priorDecision: Any?

    override func setUp() async throws {
        priorEnabled = UserDefaults.standard.object(forKey: ShareAutoCleanPreference.enabledKey)
        priorDecision = UserDefaults.standard.object(forKey: ShareAutoCleanPreference.decisionRecordedKey)
        UserDefaults.standard.set(false, forKey: ShareAutoCleanPreference.enabledKey)
        UserDefaults.standard.set(true, forKey: ShareAutoCleanPreference.decisionRecordedKey)
    }

    override func tearDown() async throws {
        restore(priorEnabled, forKey: ShareAutoCleanPreference.enabledKey)
        restore(priorDecision, forKey: ShareAutoCleanPreference.decisionRecordedKey)
    }

    func testLookAtTheListTheRunTheWaitAndTheReplySheet() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "share-look-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appending(path: "voice.m4a")
        try Data([0x53, 0x4D, 0x01, 0x35]).write(to: audio)
        let gate = LookGatedRenders()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            shareMarginSilenceAnalysisHandler: { _, _ in [] },
            shareMarginAudioCleanupHandler: { _, destinationURL, _ in
                try await gate.render(destinationURL: destinationURL)
            }
        )
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        model.selectedItem.interjections = (1...ShareBatchSeed.marginCount).map { margin in
            let transcript = ShareBatchSeed.transcript(margin: margin)
            return Interjection(
                id: ShareBatchSeed.id(margin: margin), itemId: itemID, sessionId: "session-share-look",
                targetType: .item, targetId: itemID,
                createdAt: Date(timeIntervalSince1970: TimeInterval(10 + margin)), roughPercent: min(95, margin * 15),
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: min(24, model.selectedItem.text.count),
                               anchorBefore: String(model.selectedItem.text.prefix(120)), anchorAfter: ""),
                audioPath: audio.path, audioStatus: "saved", transcriptionStatus: "transcribed",
                transcript: transcript.text, cleanedTranscript: nil, displayText: transcript.text, status: "active",
                anchorContextStatus: .ready, alignedTranscript: transcript,
                isStarredForSharing: ShareBatchSeed.starredMargins.contains(margin) ? true : nil
            )
        }
        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        model.cancelBulkSharePreparation()

        let tree = try mount(model: model, coordinator: coordinator, width: 390, height: 844)
        defer { tree.close() }
        try await settle()
        emit("01-list-open-phone", tree, pages: false)
        try await emitTall("02-list-open-full", tree, model: model, coordinator: coordinator, width: 390)
        try await emitTall("03-list-open-ipad", tree, model: model, coordinator: coordinator, width: 1024)

        // The cleanup run: the words go at once, the voices are held by the test.
        coordinator.send(.prepareAllIncluded)
        try await pollUntil { await gate.heldCount == 1 }
        try await settle()
        emit("04-run-going-phone", tree, pages: false)
        try await emitTall("05-run-going-full", tree, model: model, coordinator: coordinator, width: 390)

        // Expand the first card's change summary and its More section.
        let changed = tree.activate { $0.label == ShareReviewCardWords.showWhatChanged }
        let more = tree.activate { $0.label == ShareReviewCardWords.moreForThisMargin }
        print("SNAPSHOT-NOTE activated showWhatChanged=\(changed) moreForThisMargin=\(more)")
        try await settle()
        try await emitTall("06-card-expanded-full", tree, model: model, coordinator: coordinator, width: 390)

        // The wait: Share tapped while voices are still being made.
        coordinator.send(.beginSendWait(.file))
        print("SNAPSHOT-NOTE sendWaitCount=\(String(describing: coordinator.snapshot.sendWaitCount))")
        try await settle()
        emit("07-wait-phone", tree, pages: false)
        try await emitTall("08-wait-full", tree, model: model, coordinator: coordinator, width: 390)

        // Let the voices land: the share goes on by itself to the preview.
        try await pollUntil {
            await gate.releaseAll()
            return !model.sharingState.isBulkPreparing && model.sharingState.queuedVoiceIDs.isEmpty
        }
        try await pollUntil { coordinator.snapshot.previewState != .building && coordinator.sendWait == nil }
        try await settle()
        print("SNAPSHOT-NOTE after voices stage=\(coordinator.snapshot.stage) preview=\(coordinator.snapshot.previewState)")
        emit("09-after-voices-phone", tree, pages: false)
        try await emitTall("10-after-voices-full", tree, model: model, coordinator: coordinator, width: 390)
        if let url = coordinator.verifiedPreview?.fileURL { try? FileManager.default.removeItem(at: url) }

        // A reply sheet: its receipt, then its Choose stage.
        let replyModel = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        replyModel.resetAndSeed()
        replyModel.selectedItem.interjections = Array(model.selectedItem.interjections.prefix(2))
        replyModel.presentReplyBackShare(ReplyBackOffer(
            replies: replyModel.selectedItem.interjections, others: [], friendLabels: ["Sam"]))
        let replyCoordinator = Build23SharingCoordinator(model: replyModel)
        replyCoordinator.send(.begin)
        replyModel.cancelBulkSharePreparation()
        let replyTree = try mount(model: replyModel, coordinator: replyCoordinator, width: 390, height: 844)
        defer { replyTree.close() }
        try await settle()
        emit("11-reply-receipt-phone", replyTree, pages: false)
        replyCoordinator.send(.returnToSelect)
        try await settle()
        print("SNAPSHOT-NOTE reply stage=\(replyCoordinator.snapshot.stage)")
        emit("12-reply-choose-phone", replyTree, pages: false)
        replyCoordinator.send(.advanceToReview)
        try await settle()
        emit("13-reply-back-to-review-phone", replyTree, pages: false)
    }

    // MARK: -

    private func mount(model: Gate1AppModel, coordinator: Build23SharingCoordinator,
                       width: CGFloat, height: CGFloat) throws -> MountedTree {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: AnyView(
            Build23SenderSharingExperience(coordinator: coordinator).environmentObject(model)))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return MountedTree(window: window, previousKeyWindow: previousKeyWindow)
    }

    private func settle() async throws {
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(150))
            await Task.yield()
        }
    }

    /// Re-lays the window out tall enough to hold the whole list, emits it in pages, and puts the phone size back.
    private func emitTall(_ name: String, _ tree: MountedTree, model: Gate1AppModel,
                          coordinator: Build23SharingCoordinator, width: CGFloat) async throws {
        tree.window.frame = CGRect(x: 0, y: 0, width: width, height: 4200)
        try await settle()
        emit(name, tree, pages: true)
        tree.window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        try await settle()
    }

    private func emit(_ name: String, _ tree: MountedTree, pages: Bool) {
        let window = tree.window
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let labels = tree.nodes().compactMap { node -> String? in
            guard let label = node.label, !label.isEmpty else { return nil }
            return "\(label)@\(Int(node.frame.minY))"
        }
        print("SNAPSHOT-LABELS \(name) \(labels.joined(separator: " | "))")
        let pageHeight: CGFloat = pages ? 900 : window.bounds.height
        var top: CGFloat = 0
        var index = 0
        while top < window.bounds.height {
            let rect = CGRect(x: 0, y: top, width: window.bounds.width,
                              height: min(pageHeight, window.bounds.height - top))
            let page = UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: rect.size), format: format).image { _ in
                image.draw(at: CGPoint(x: 0, y: -top))
            }
            if let data = page.jpegData(compressionQuality: 0.6) {
                let encoded = data.base64EncodedString()
                let label = "\(name)-p\(index)"
                print("SNAPSHOT-BEGIN \(label)")
                var start = encoded.startIndex
                while start < encoded.endIndex {
                    let end = encoded.index(start, offsetBy: 3000, limitedBy: encoded.endIndex) ?? encoded.endIndex
                    print("SNAPSHOT-DATA \(label) \(encoded[start..<end])")
                    start = end
                }
                print("SNAPSHOT-END \(label)")
            }
            top += pageHeight
            index += 1
        }
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private actor LookGatedRenders {
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int { held.count }

    func render(destinationURL: URL) async throws -> Int {
        await withCheckedContinuation { held.append($0) }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01, 0x02, 0x03]).write(to: destinationURL)
        return 600
    }

    func releaseAll() {
        let released = held
        held = []
        released.forEach { $0.resume() }
    }
}
