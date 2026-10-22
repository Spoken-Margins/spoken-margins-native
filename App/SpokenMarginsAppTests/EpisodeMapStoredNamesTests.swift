import AVFoundation
import CryptoKit
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SessionKitSharing
import XCTest
@testable import SpokenMarginsApp

/// P19: read the rows saved by the app, rather than rebuilding its private naming rules in tests.
@MainActor
final class EpisodeMapStoredNamesTests: XCTestCase {
    func testUndownloadedPodcastJobIDsKeepSanitizingAndNinetySixCharacterLimit() throws {
        preserveVoiceDefaults()
        // Every expected saved name is a literal. In particular, do not use the production sanitizer here.
        let cases: [(itemID: String, jobID: String)] = [
            ("p19 space", "episode-map-job-p19-space"),
            ("p19:colon", "episode-map-job-p19-colon"),
            ("p19/slash", "episode-map-job-p19-slash"),
            ("p19-caf\u{E9}", "episode-map-job-p19-caf-"),
            ("p19-cafe\u{301}", "episode-map-job-p19-cafe-"),
            ("P19._-  two", "episode-map-job-P19._---two"),
            ("", "episode-map-job-unknown"),
            ("p19-" + String(repeating: "a", count: 92) + "-discarded",
             "episode-map-job-p19-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        ]
        for entry in cases {
            // One library per case. Swift's `String ==` (and the model's "is there already a job for this
            // item" lookup) treat "caf\u{E9}" and "cafe\u{301}" as the same string, so in a shared library the
            // second spelling reuses the first one's job and never gets its own. That lookup is not what this
            // test pins; the saved name for each spelling is.
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                      databaseURLOverride: root.appending(path: "library.sqlite"))
            let store = try model.libraryStoreForTesting()
            // No local copy and no remote URL: the job must be saved before waiting, without starting networking.
            try store.saveItem(Item(id: entry.itemID, title: "P19 undownloaded podcast",
                mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
                externalReference: nil, status: "ready",
                media: ItemMedia(sourceType: .remoteStream, durationMs: 10_000)))
            model.prepareEpisodeMap(itemId: entry.itemID)
            let jobs = try store.loadEpisodeMapPreparationJobs()
            XCTAssertEqual(jobs.count, 1, entry.itemID.debugDescription)
            let job = try XCTUnwrap(jobs.first)
            // Compare stored text as scalars: `String ==` would also accept the other spelling of an accent.
            XCTAssertEqual(Array(job.itemId.unicodeScalars), Array(entry.itemID.unicodeScalars),
                           entry.itemID.debugDescription)
            XCTAssertEqual(Array(job.id.unicodeScalars), Array(entry.jobID.unicodeScalars),
                           entry.itemID.debugDescription)
            XCTAssertEqual(job.stage, .verifySource)
            XCTAssertTrue(model.diagnostics["episodeMapPreparation:\(entry.itemID)"]?.hasPrefix("waiting_for_local_audio:trigger=listener_request:at=") == true)
        }
    }

    func testSystemSummarySavesChosenVoiceAndRenderedExtension() async throws {
        let asset = try await importSummary(itemID: "p19-system 996:\u{E9}/A.1_",
            safeItemDirectory: "p19-system-996---A.1_", voice: .system, renderedExtension: "m4a")
        XCTAssertEqual(asset.id,
            "summary-bridge-p19-system-996---A.1_-p19-map-996-xbbdab9273043b5f0-p19-scene-1-xb2b41cd1af2794ab-system-com.apple.voice.test-en_US-natural-rate-v2")
        XCTAssertEqual(asset.relativePath,
            "SpokenMargins/EpisodeMaps/p19-system-996---A.1_/SummaryBridges/summary-bridge-p19-system-996---A.1_-p19-map-996-xbbdab9273043b5f0-p19-scene-1-xb2b41cd1af2794ab-system-com.apple.voice.test-en_US-natural-rate-v2.m4a")
    }

    func testSystemSummaryWithoutRenderedExtensionSavesCAFFallback() async throws {
        let asset = try await importSummary(itemID: "p19-extensionless-996",
            safeItemDirectory: "p19-extensionless-996", voice: .system, renderedExtension: "")
        XCTAssertEqual(asset.id,
            "summary-bridge-p19-extensionless-996-p19-map-996-xbbdab9273043b5f0-p19-scene-1-xb2b41cd1af2794ab-system-com.apple.voice.test-en_US-natural-rate-v2")
        XCTAssertEqual(asset.relativePath,
            "SpokenMargins/EpisodeMaps/p19-extensionless-996/SummaryBridges/summary-bridge-p19-extensionless-996-p19-map-996-xbbdab9273043b5f0-p19-scene-1-xb2b41cd1af2794ab-system-com.apple.voice.test-en_US-natural-rate-v2.caf")
    }

    func testJamesSummaryWithoutSupertonicDownloadSavesKittenKeyAndEmptySystemIdentifier() async throws {
        // Supertonic's model is a download (#1820), so on the lane James has none and the bundled Kitten voice speaks
        // the summary. The asset ID names Kitten, not James, and the supplied system identifier must not appear in it.
        let asset = try await importSummary(itemID: "p19-james-996",
            safeItemDirectory: "p19-james-996", voice: .james)
        XCTAssertEqual(asset.id,
            "summary-bridge-p19-james-996-p19-map-996-xbbdab9273043b5f0-p19-scene-1-xb2b41cd1af2794ab-kitten--natural-rate-v2")
        XCTAssertEqual(asset.relativePath,
            "SpokenMargins/EpisodeMaps/p19-james-996/SummaryBridges/summary-bridge-p19-james-996-p19-map-996-xbbdab9273043b5f0-p19-scene-1-xb2b41cd1af2794ab-kitten--natural-rate-v2.wav")
    }

    func testSuppliedAuthorSummarySavesSuppliedKeyAndM4AImportPath() async throws {
        let asset = try await importSummary(itemID: "p19-author-996",
            safeItemDirectory: "p19-author-996", voice: .system, supplied: true)
        XCTAssertEqual(asset.id,
            "summary-bridge-p19-author-996-p19-map-996-xbbdab9273043b5f0-p19-scene-1-xb2b41cd1af2794ab-supplied-p19-author--caf--xb05344fc930f4c44")
        XCTAssertEqual(asset.relativePath,
            "SpokenMargins/EpisodeMaps/p19-author-996/SummaryBridges/summary-bridge-p19-author-996-p19-map-996-xbbdab9273043b5f0-p19-scene-1-xb2b41cd1af2794ab-supplied-p19-author--caf--xb05344fc930f4c44.m4a")
        XCTAssertFalse(asset.isReproducible, "The author's voice is adopted, not synthesized")
    }

    /// #1120: a voice a hand-made packet supplied before ids carried a hash sits under the old cut name. It is still
    /// found, not detached and not "prepared" again.
    func testASuppliedVoiceSavedUnderTheOldCutNameStillCountsAsPrepared() async throws {
        preserveVoiceDefaults()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: root.appending(path: "library.sqlite"))
        let store = try model.libraryStoreForTesting()
        try store.saveItem(Item(id: "p1120-item", title: "P1120", mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil, externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .remoteStream, durationMs: 10_000)))
        let oldVoice = root.appending(path: "old-voice.m4a")
        try Self.writeAudio(to: oldVoice)
        let oldName = "summary-bridge-p1120-item-p1120-map-p1120-scene-supplied-v-"
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(id: oldName, itemId: "p1120-item", category: .summaryBridge,
            relativePath: oldVoice.path, byteCount: 1, isReproducible: false))
        let scene = PortableListeningMapScene(id: "p1120-scene", order: 0, title: "Summary",
            summaryText: "Hello.", summaryAssetId: "v\u{E9}", summaryProvenance: .modelGenerated, eligibility: .eligible,
            startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 0),
            endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000))
        let found = try await model.prepareSummaryBridgeAsset(itemId: "p1120-item", proposalId: "p1120-map", scene: scene, store: store)
        XCTAssertEqual(found?.id, oldName)
        XCTAssertNotEqual(model.summaryBridgeAssetID(itemId: "p1120-item", proposalId: "p1120-map", sceneId: "p1120-scene",
                                                    suppliedAssetId: "v\u{E9}"), oldName, "new imports use the hashed name")
    }

    /// The exact-audio packet fixture from LocalAudioListeningPackageTests, reduced to one scene.
    /// No playback, transcription, fingerprint generation, or ShazamKit is needed to adopt this map.
    private func importSummary(
        itemID: String, safeItemDirectory: String, voice: AppTTSVoiceSelection,
        renderedExtension: String = "m4a", supplied: Bool = false
    ) async throws -> OwnedOfflineAsset {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        preserveVoiceDefaults()
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        // Golden item IDs are distinct and reserved to this class. Refuse a pre-existing directory
        // so a failed earlier run (or any other library) can never be overwritten or cleaned up.
        let maps = support.appending(path: "SpokenMargins/EpisodeMaps")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        let ownedDirectory = maps.appending(path: safeItemDirectory)
        guard !FileManager.default.fileExists(atPath: ownedDirectory.path) else {
            throw NSError(domain: "EpisodeMapStoredNamesTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Refusing existing fixture directory: \(ownedDirectory.path)"])
        }
        try FileManager.default.createDirectory(at: ownedDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: ownedDirectory) }

        let sourcePath = "Audiobooks/p19-\(UUID().uuidString).caf"
        let sourceURL = support.appending(path: sourcePath)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try Self.writeAudio(to: sourceURL)
        let bytes = try Data(contentsOf: sourceURL)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
            preparedTextAudioPrewarmHandler: { _, _, text, directory, _, _ in
                // Use an unrelated filename so the test also proves the app copies/renames the output.
                let name = renderedExtension.isEmpty ? "rendered" : "rendered.\(renderedExtension)"
                let url = directory.appending(path: name)
                do {
                    try Self.writeAudio(to: url)
                    return .success(PreparedTextAudio(normalizedText: text,
                        media: ItemMedia(sourceType: .generatedTTSPrerendered,
                            url: url.absoluteString, durationMs: 1_000),
                        timeline: TranscriptTimeline(segments: [], chapters: [], durationMs: 1_000)))
                } catch { return .failure(error) }
            }, databaseURLOverride: root.appending(path: "library.sqlite"))
        model.resetAndSeed()
        let store = try model.libraryStoreForTesting()
        let item = Item(id: itemID, title: "P19 exact audio", mediaType: "audiobook", text: nil,
            externalReference: sourceURL.absoluteString, status: "ready", externalReferenceType: "audiobook",
            media: ItemMedia(sourceType: .nativeMediaFile, url: sourceURL.absoluteString,
                durationMs: 1_000, nativeMediaId: "p19-source"))
        try store.saveItem(item)
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(id: "p19-source", itemId: itemID,
            category: .audiobook, relativePath: sourcePath, byteCount: Int64(bytes.count),
            checksumSHA256: digest, isReproducible: false))
        // These tests expect Kitten to speak James's summary; with a Supertonic download present, James would.
        try XCTSkipIf(voice == .james && model.supertonicModel.isModelPresent,
            "a Supertonic download is present, so James would render the summary himself")
        if voice == .james { model.acceptCurrentTermsAndEnableOnDeviceVoice() }
        model.ttsVoiceSelection = voice
        model.speechVoiceIdentifier = "com.apple.voice.test:en_US"

        let suppliedID = "p19-author:/caf\u{E9}"
        let proposal = PortableListeningMapProposalArtifact(id: "p19:map/996", createdAt: Date(), generator: "test",
            scenes: [PortableListeningMapScene(id: "p19:scene/1", order: 0, title: "Summary",
                summaryText: "Hello.", summaryAssetId: supplied ? suppliedID : nil,
                summaryProvenance: .modelGenerated, eligibility: .eligible,
                startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 0),
                endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000))])
        let revision = InterjectionShareRevision(id: "revision", interjectionId: "margin", itemId: "sender",
            sessionId: "sender-session", createdAt: Date(), approvedTranscript: "Listen here.",
            anchorBefore: "", anchorAfter: "", status: .senderApproved)
        let prepared = try SpokenMarginsPackageBuilder.prepare(packageId: "p19-\(UUID().uuidString)", createdAt: Date(),
            item: SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: digest),
            itemTransportSelection: .recipientSupplied,
            selections: [ReviewedInterjectionSelection(packageScopedId: "p19-margin", revision: revision,
                anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 0), representation: .textOnly)],
            mapProposals: [proposal], senderDisplayLabel: "P19")
        var manifest = prepared.manifest
        var assetFiles: [String: URL] = [:]
        if supplied {
            let summaryURL = root.appending(path: "author.m4a")
            try Self.writeAudio(to: summaryURL)
            manifest.assets.append(SpokenMarginsAssetDescriptor(id: suppliedID,
                role: SpokenMarginsAssetRole.summaryVoice, path: "assets/audio/author.m4a",
                mimeType: "audio/mp4", durationMs: 1_000, provenance: "sender_approved_tts"))
            assetFiles["assets/audio/author.m4a"] = summaryURL
        }
        let packetURL = root.appending(path: "summary.spokenmargins")
        _ = try SpokenMarginsPackageArchive.write(PreparedSpokenMarginsPackage(manifest: manifest,
            artifactData: prepared.artifactData, assetFiles: assetFiles), to: packetURL)
        model.handleIncomingURL(packetURL)
        XCTAssertEqual(model.spokenMarginsPackageImportReview?.matchingItemId, itemID)
        model.confirmSpokenMarginsPackageImport()
        for _ in 0..<500 where model.isImportingSpokenMarginsPackage {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isImportingSpokenMarginsPackage)
        XCTAssertNil(model.spokenMarginsPackageImportError)
        // The injected renderer is immediate; James's summary is rendered by Kitten, which loads its bundled model on a busy lane.
        let bridgePolls = voice == .james ? 3_000 : 500
        for _ in 0..<bridgePolls where model.diagnostics["localAudioSkim:\(itemID)"] != "ready"
            && model.diagnostics["localAudioSkim:\(itemID)"]?.hasPrefix("failed:") != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.diagnostics["localAudioSkim:\(itemID)"], "ready")
        let assets = try store.loadOwnedOfflineAssets().filter { $0.itemId == itemID && $0.category == .summaryBridge }
        XCTAssertEqual(assets.count, 1)
        let asset = try XCTUnwrap(assets.first)
        XCTAssertEqual(asset.integrity, .valid)
        let savedFile = support.appending(path: asset.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedFile.path))
        XCTAssertEqual(try savedFile.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init), asset.byteCount)
        // Also read through a new SQLite connection: these are durable names, not just model state.
        let reopened = try SQLiteSessionStore(path: root.appending(path: "library.sqlite").path)
        let saved = try XCTUnwrap(reopened.loadOwnedOfflineAssets().first { $0.id == asset.id })
        XCTAssertEqual(saved.relativePath, asset.relativePath)
        return saved
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "p19-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func preserveVoiceDefaults() {
        let keys = [SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey,
            "supertonicVoicePendingTermsV1", "supertonicTTSMigrationV1", "ttsVoiceSelection", "ttsMode", "speechVoiceIdentifier",
            "speechRate", "piperVoiceId", "renderedSpeechCacheLimitMB"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        addTeardownBlock {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    nonisolated private static func writeAudio(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { channel[index] = sin(Float(index) * 0.03) * 0.02 }
        let settings: [String: Any] = url.pathExtension == "m4a"
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
            : format.settings
        let output = url.pathExtension.isEmpty ? url.appendingPathExtension("caf") : url
        do {
            let file = try AVAudioFile(forWriting: output, settings: settings)
            try file.write(from: buffer)
        }
        if output != url { try FileManager.default.moveItem(at: output, to: url) }
    }
}
