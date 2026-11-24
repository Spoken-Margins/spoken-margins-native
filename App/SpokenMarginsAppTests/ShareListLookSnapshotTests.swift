import AVFoundation
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// THROWAWAY (#5180, do not merge): draws the Share Margins sheet in the simulator at each state the PR's look check
/// names, and prints each picture as base64 JPEG pages into the test log, so a session with no simulator of its own can
/// look at it through branch-t3's log artifact. Each sheet is opened the way the app opens it: the view's own onAppear
/// sends `.begin`, once.
@MainActor
final class ShareListLookSnapshotTests: XCTestCase {
    private var priorEnabled: Any?
    private var priorDecision: Any?
    private var automationWasEnabled: Int32?
    private var root: URL!

    override func setUp() async throws {
        priorEnabled = UserDefaults.standard.object(forKey: ShareAutoCleanPreference.enabledKey)
        priorDecision = UserDefaults.standard.object(forKey: ShareAutoCleanPreference.decisionRecordedKey)
        UserDefaults.standard.set(false, forKey: ShareAutoCleanPreference.enabledKey)
        UserDefaults.standard.set(true, forKey: ShareAutoCleanPreference.decisionRecordedKey)
        automationWasEnabled = AccessibilityAutomation.enable()
        root = FileManager.default.temporaryDirectory.appending(path: "share-look-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        restore(priorEnabled, forKey: ShareAutoCleanPreference.enabledKey)
        restore(priorDecision, forKey: ShareAutoCleanPreference.decisionRecordedKey)
        if let automationWasEnabled { AccessibilityAutomation.set(automationWasEnabled) }
        try? FileManager.default.removeItem(at: root)
    }

    func testA_TheListTheRunAndTheWait() async throws {
        let gate = LookGatedRenders()
        let model = try makeModel(gate: gate)
        model.prepareShareInterjections()
        let coordinator = Build23SharingCoordinator(model: model)
        let tree = try mount(model: model, coordinator: coordinator)
        defer { tree.close() }
        try await settle()
        note("A list open: stage=\(coordinator.snapshot.stage) showsList=\(coordinator.snapshot.showsList)")
        try await emitScrolled("A1-list-open", tree)

        // Show every Margin, so the left-out ones show too.
        coordinator.send(.setFilter(.all))
        try await settle()
        try await emitScrolled("A2-list-all", tree)

        // The cleanup run from the switch: the words go at once, the voices are held by the test.
        coordinator.send(.setAutoCleanSelectedEnabled(true))
        try await pollUntil(timeout: .seconds(10)) { await gate.heldCount == 1 }
        try await settle()
        note("A run: held=\(await gate.heldCount) readiness=\(coordinator.snapshot.readiness)")
        try await emitScrolled("A3-run-going", tree)

        // Open the first included card's change summary and its More section.
        scrollToTop(tree)
        try await settle()
        let changed = tree.activate { $0.label == ShareReviewCardWords.showWhatChanged }
        try await settle()
        let more = tree.activate { $0.label == ShareReviewCardWords.moreForThisMargin }
        try await settle()
        note("A activated showWhatChanged=\(changed) moreForThisMargin=\(more)")
        try await emitScrolled("A4-card-opened", tree)

        // The wait: Share tapped while voices are still being made.
        coordinator.send(.beginSendWait(.file))
        try await settle()
        note("A wait: sendWaitCount=\(String(describing: coordinator.snapshot.sendWaitCount))")
        scrollToTop(tree)
        try await settle()
        emit("A5-wait-top", tree)

        coordinator.send(.stopSendWait)
        try await settle()
        note("A stopped: sendWait=\(String(describing: coordinator.sendWait))")
        emit("A6-after-stop-sharing", tree)
        try await pollUntil {
            await gate.releaseAll()
            return !model.sharingState.isBulkPreparing && model.sharingState.queuedVoiceIDs.isEmpty
        }
    }

    func testB_ThePreviewOfAListSheet() async throws {
        let model = try makeModel(gate: LookGatedRenders())
        model.prepareShareInterjections()
        let coordinator = Build23SharingCoordinator(model: model)
        let tree = try mount(model: model, coordinator: coordinator)
        defer { tree.close() }
        try await settle()
        coordinator.send(.buildRecipientPreview)
        try await pollUntil { coordinator.snapshot.previewState != .building }
        try await settle()
        note("B preview: stage=\(coordinator.snapshot.stage) preview=\(coordinator.snapshot.previewState)")
        try await emitScrolled("B1-preview", tree)
        if let url = coordinator.verifiedPreview?.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    func testC_TheReplySheet() async throws {
        let model = try makeModel(gate: LookGatedRenders())
        model.selectedItem.interjections = Array(model.selectedItem.interjections.prefix(2))
        model.presentReplyBackShare(ReplyBackOffer(
            replies: model.selectedItem.interjections, others: [], friendLabels: ["Sam"]))
        let coordinator = Build23SharingCoordinator(model: model)
        let tree = try mount(model: model, coordinator: coordinator)
        defer { tree.close() }
        try await settle()
        note("C reply open: stage=\(coordinator.snapshot.stage) isReplyBack=\(coordinator.snapshot.isReplyBack)")
        try await emitScrolled("C1-reply-receipt", tree)
        coordinator.send(.returnToSelect)
        try await settle()
        note("C reply back: stage=\(coordinator.snapshot.stage)")
        try await emitScrolled("C2-reply-choose", tree)
    }

    // MARK: -

    private func makeModel(gate: LookGatedRenders) throws -> Gate1AppModel {
        let audio = root.appending(path: "voice-\(UUID().uuidString).m4a")
        try writeTone(to: audio, seconds: Double(ShareBatchSeed.durationMs(margin: 1)) / 1000 + 1)
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
        return model
    }

    private func writeTone(to url: URL, seconds: Double) throws {
        let rate = 22_050.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) { channel[index] = 0.2 * sinf(Float(index) * 2 * .pi * 220 / Float(rate)) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    private func mount(model: Gate1AppModel, coordinator: Build23SharingCoordinator) throws -> MountedTree {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: AnyView(
            Build23SenderSharingExperience(coordinator: coordinator).environmentObject(model)))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        return MountedTree(window: window, previousKeyWindow: previousKeyWindow)
    }

    private func settle() async throws {
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(150))
            await Task.yield()
        }
    }

    private func note(_ text: String) {
        print("SNAPSHOT-NOTE \(text)")
    }

    private func scrollView(in tree: MountedTree) -> UIScrollView? {
        func find(_ view: UIView) -> [UIScrollView] {
            var found: [UIScrollView] = []
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 1 { found.append(scroll) }
            for sub in view.subviews { found += find(sub) }
            return found
        }
        return find(tree.window).max { $0.contentSize.height < $1.contentSize.height }
    }

    private func scrollToTop(_ tree: MountedTree) {
        guard let scroll = scrollView(in: tree) else { return }
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
    }

    /// Emits the screen, then pages down the main scroll view to its end, emitting each page.
    private func emitScrolled(_ name: String, _ tree: MountedTree) async throws {
        guard let scroll = scrollView(in: tree) else {
            note("\(name) no scroll view taller than the screen")
            emit("\(name)-s0", tree)
            return
        }
        let top = -scroll.adjustedContentInset.top
        let bottom = max(top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        let step = max(200, scroll.bounds.height - scroll.adjustedContentInset.bottom - scroll.adjustedContentInset.top - 60)
        note("\(name) scroll content=\(Int(scroll.contentSize.height)) bounds=\(Int(scroll.bounds.height)) step=\(Int(step))")
        var offset = top
        var index = 0
        while true {
            scroll.setContentOffset(CGPoint(x: 0, y: min(offset, bottom)), animated: false)
            try await settle()
            emit("\(name)-s\(index)", tree)
            if offset >= bottom || index >= 14 { break }
            offset += step
            index += 1
        }
        scroll.setContentOffset(CGPoint(x: 0, y: top), animated: false)
        try await settle()
    }

    private func emit(_ name: String, _ tree: MountedTree) {
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
        guard let data = image.jpegData(compressionQuality: 0.55) else { return }
        let encoded = data.base64EncodedString()
        // Twice, so one copy survives when another process's log line lands inside the other.
        for copy in ["a", "b"] {
            let label = "\(name)-\(copy)"
            var start = encoded.startIndex
            while start < encoded.endIndex {
                let end = encoded.index(start, offsetBy: 2000, limitedBy: encoded.endIndex) ?? encoded.endIndex
                print("SNAPSHOT-DATA \(label) \(encoded[start..<end])")
                start = end
            }
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
