import XCTest
import AVFoundation
import CryptoKit
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SessionKitSharing
@testable import SpokenMarginsApp

@MainActor
final class LocalAudioListeningPackageTests: XCTestCase {
    func testExactAudioImportActivatesMapResolvesMarginsAndSurvivesReconstruction() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let store = try SQLiteSessionStore(path: db.path)
        let sourcePlayer = AVPlayerStreamPlaybackClient()
        let routed = RoutedAudioPlaybackClient(speech: NoopAudioPlaybackClient(), media: sourcePlayer)
        let model = Gate1AppModel(audioPlaybackClient: routed, databaseURLOverride: db)
        model.resetAndSeed()
        model.ttsVoiceSelection = .system
        let audio = root.appending(path: "source.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { channel[i] = sin(Float(i) * 0.03) * 0.02 }
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        try file.write(from: buffer)
        let bytes = try Data(contentsOf: audio)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let item = Item(id: "local-test", title: "Exact local source", mediaType: "audiobook", text: nil, externalReference: audio.absoluteString, status: "ready", externalReferenceType: "audiobook", media: ItemMedia(sourceType: .nativeMediaFile, url: audio.absoluteString, durationMs: 10_000, nativeMediaId: "source-audio"))
        try store.seed(item: item)
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(id: "owned", itemId: item.id, category: .audiobook, relativePath: "source.caf", byteCount: Int64(bytes.count), checksumSHA256: hash, isReproducible: false))
        let identity = model.localSharedItemIdentity(for: item)
        XCTAssertEqual(identity.itemType, .other)
        XCTAssertEqual(identity.exactEditionSHA256, hash)
        let proposal = PortableListeningMapProposalArtifact(id: "local-map", createdAt: Date(), generator: "test", scenes: (0..<2).map { index in
            PortableListeningMapScene(id: "scene-\(index)", order: index, title: "Scene \(index)", summaryText: "A short recap.", summaryAssetId: "supplied-summary", summaryProvenance: .modelGenerated, eligibility: .eligible, startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: index * 5_000), endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: (index + 1) * 5_000))
        })
        let revision = InterjectionShareRevision(id: "revision", interjectionId: "margin", itemId: "sender", sessionId: "sender-session", createdAt: Date(), approvedTranscript: "What assumption matters?", anchorBefore: "", anchorAfter: "", status: .senderApproved)
        let prepared = try SpokenMarginsPackageBuilder.prepare(packageId: "test-local-audio", createdAt: Date(), item: identity, itemTransportSelection: .recipientSupplied, selections: [ReviewedInterjectionSelection(packageScopedId: "professor", revision: revision, anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000), representation: .textOnly)], mapProposals: [proposal], senderDisplayLabel: "AI professor")
        // A real AAC asset exercises adoption/playback without an OS voice download.
        let summaryURL = root.appending(path: "summary.m4a")
        try writeSummaryAudio(to: summaryURL)
        var envelope = prepared.manifest
        envelope.assets.append(SpokenMarginsAssetDescriptor(id: "supplied-summary", role: SpokenMarginsAssetRole.summaryVoice, path: "assets/audio/summary.m4a", mimeType: "audio/mp4", durationMs: 1_000, provenance: "sender_approved_tts"))
        let voiced = PreparedSpokenMarginsPackage(manifest: envelope, artifactData: prepared.artifactData, assetFiles: ["assets/audio/summary.m4a": summaryURL])
        let url = root.appending(path: "session.spokenmargins")
        let manifest = try SpokenMarginsPackageArchive.write(voiced, to: url)
        model.handleIncomingURL(url)
        XCTAssertEqual(model.spokenMarginsPackageImportReview?.matchingItemId, item.id)
        model.confirmSpokenMarginsPackageImport()
        for _ in 0..<250 where model.isImportingSpokenMarginsPackage { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.spokenMarginsPackageImportError)
        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: try XCTUnwrap(manifest.contentDigest)))
        XCTAssertEqual(layer.sourceResolutionStatus, .resolved)
        XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: layer.id).first?.resolution.localMediaTimeMs, 1_000)
        XCTAssertEqual(model.selectedItem.listeningMapScenes.map(\.startMs), [0, 5_000])
        XCTAssertNil(model.snapshot.sessionId, "Import must not autoplay")
        XCTAssertEqual(try store.loadResolvedListeningMapProjection(itemId: item.id)?.projectedRecipientTime(for: 5_000), 5_000)
        // Supplied bridges must be ready without any system or inference synthesis.
        for _ in 0..<750 where model.diagnostics["localAudioSkim:\(item.id)"] != "ready" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.diagnostics["localAudioSkim:\(item.id)"], "ready")
        model.startItem(id: item.id)
        // Exercise the real source adapter: nativeMediaId is an asset ID, not a URL.
        for _ in 0..<150 where (sourcePlayer.currentMediaTimeMs() ?? 0) < 200 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(sourcePlayer.currentMediaTimeMs() ?? 0, 100, "Source audio must actually advance before Skim")
        model.pause()
        let pausedTime = sourcePlayer.currentMediaTimeMs() ?? 0
        model.resumePlayback()
        for _ in 0..<150 where (sourcePlayer.currentMediaTimeMs() ?? 0) < pausedTime + 200 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(sourcePlayer.currentMediaTimeMs() ?? 0, pausedTime + 100)
        XCTAssertTrue(model.snapshot.canSkimForward)
        let loadedResources = model.skimResourceLoadCount
        for _ in 0..<40 { model.snapshot.currentMediaTimeMs = model.snapshot.currentMediaTimeMs }
        XCTAssertEqual(model.skimResourceLoadCount, loadedResources, "Progress updates must reuse the loaded map and asset metadata")
        let priorRate = model.mediaPlaybackRate
        model.setMediaPlaybackRate(1.75)
        model.skimForward()
        XCTAssertEqual(model.skimAudioTransportRate, 1.75, "Skim must apply listening speed in AVPlayer")
        model.setMediaPlaybackRate(1.25)
        XCTAssertEqual(model.skimAudioTransportRate, 1.25, "A rate change must update the active summary player")
        model.setMediaPlaybackRate(priorRate)
        XCTAssertEqual(model.snapshot.skimBridgeState?.destinationMediaTimeMs, 5_000)
        model.skimForward()
        XCTAssertNil(model.snapshot.skimBridgeState, "Second Skim tap exits instead of restarting or chaining a summary")
        for _ in 0..<500 where model.snapshot.skimBridgeState != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.snapshot.skimBridgeState)
        for _ in 0..<150 where (sourcePlayer.currentMediaTimeMs() ?? 0) < 5_200 {
            // Crossing the test Margin opens Companion's intentional pause.
            // Dismiss it just as the listener would before expecting progress.
            if model.pendingImportedCommentary != nil { model.dismissPendingImportedCommentary() }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(sourcePlayer.currentMediaTimeMs() ?? 0, 5_100, "Skim must return to progressing source audio: status=\(model.snapshot.status), failure=\(model.snapshot.lastFailure ?? "none"), pending=\(model.pendingImportedCommentary != nil)")
        model.pause()
        // Reproduce a device update: the durable item URL points at a former
        // container, while the owned asset remains under the current support root.
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let relocatedPath = "Audiobooks/relocated-\(UUID().uuidString).caf"
        let relocatedURL = support.appending(path: relocatedPath)
        try FileManager.default.createDirectory(at: relocatedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: audio, to: relocatedURL)
        defer { try? FileManager.default.removeItem(at: relocatedURL) }
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(id: "owned", itemId: item.id, category: .audiobook, relativePath: relocatedPath, byteCount: Int64(bytes.count), checksumSHA256: hash, isReproducible: false))
        let resumedPlayer = AVPlayerStreamPlaybackClient()
        let reconstructed = Gate1AppModel(audioPlaybackClient: RoutedAudioPlaybackClient(speech: NoopAudioPlaybackClient(), media: resumedPlayer), databaseURLOverride: db)
        reconstructed.bootstrapLibraryIfNeeded()
        reconstructed.openItem(id: item.id)
        XCTAssertEqual(reconstructed.selectedItem.listeningMapScenes.count, 2)
        reconstructed.startItem(id: item.id)
        let resumedAt = reconstructed.snapshot.currentMediaTimeMs ?? 0
        for _ in 0..<150 where (resumedPlayer.currentMediaTimeMs() ?? 0) < resumedAt + 200 {
            if reconstructed.pendingImportedCommentary != nil { reconstructed.dismissPendingImportedCommentary() }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(resumedPlayer.currentMediaTimeMs() ?? 0, resumedAt + 100, "Saved-session playback must survive container relocation")
        reconstructed.pause()
        // The supplied voice survives a user voice preference change.
        model.ttsVoiceSelection = .james
        model.openItem(id: item.id)
        XCTAssertTrue(model.snapshot.canSkimForward)
        // A stale catalog digest cannot authorize modified source bytes.
        try Data("changed source".utf8).write(to: relocatedURL)
        let changedEnvelope = SpokenMarginsPackageManifest(packageId: "tampered-source-check", createdAt: Date(), item: identity, itemTransport: envelope.itemTransport, requiredCapabilities: envelope.requiredCapabilities, artifacts: envelope.artifacts, assets: envelope.assets, redactions: envelope.redactions)
        let tampered = PreparedSpokenMarginsPackage(manifest: changedEnvelope, artifactData: prepared.artifactData, assetFiles: ["assets/audio/summary.m4a": summaryURL])
        let anotherURL = root.appending(path: "tampered.spokenmargins")
        _ = try SpokenMarginsPackageArchive.write(tampered, to: anotherURL)
        model.handleIncomingURL(anotherURL)
        model.confirmSpokenMarginsPackageImport()
        for _ in 0..<250 where model.isImportingSpokenMarginsPackage { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.spokenMarginsPackageImportError?.contains("audio bytes do not match") == true)
        XCTAssertEqual(try store.loadImportedCommentaryLayers(itemId: item.id).count, 1)
    }

    private func writeSummaryAudio(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<24_000 { channel[i] = sin(Float(i) * 0.03) * 0.02 }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        try file.write(from: buffer)
    }
}
