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
        // A fresh simulator parks the improved voice as a pending first-use choice, and startItem
        // waits for it. Earlier classes used to make that choice for this one (#286).
        model.declineCurrentTerms()
        // The offline ledger is rooted at Application Support and reconciles
        // rows against disk, so the owned file lives where production puts it.
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let sourcePath = "Audiobooks/source-\(UUID().uuidString).caf"
        let audio = support.appending(path: sourcePath)
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audio) }
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
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(id: "owned", itemId: item.id, category: .audiobook, relativePath: sourcePath, byteCount: Int64(bytes.count), checksumSHA256: hash, isReproducible: false))
        let identity = SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: hash)
        XCTAssertEqual(identity.itemType, .other)
        XCTAssertEqual(identity.exactEditionSHA256, hash)
        let proposal = PortableListeningMapProposalArtifact(id: "local-map", createdAt: Date(), generator: "test", scenes: (0..<2).map { index in
            PortableListeningMapScene(id: "scene-\(index)", order: index, title: "Scene \(index)", summaryText: "A short recap.", summaryAssetId: "supplied-summary", summaryProvenance: .modelGenerated, eligibility: .eligible, startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: index * 5_000), endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: (index + 1) * 5_000))
        })
        let revision = InterjectionShareRevision(id: "revision", interjectionId: "margin", itemId: "sender", sessionId: "sender-session", createdAt: Date(), approvedTranscript: "What assumption matters?", anchorBefore: "", anchorAfter: "", status: .senderApproved)
        let prepared = try SpokenMarginsPackageBuilder.prepare(packageId: "test-local-audio", createdAt: Date(), item: identity, itemTransportSelection: .recipientSupplied, selections: [ReviewedInterjectionSelection(packageScopedId: "professor", revision: revision, anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000), representation: .textOnly)], mapProposals: [proposal], senderDisplayLabel: "AI professor")
        // A real AAC asset exercises adoption/playback without an OS voice download.
        let summaryURL = root.appending(path: "summary.m4a")
        try Self.writeSummaryAudio(to: summaryURL)
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
        XCTAssertFalse(model.isTermsOfUsePresented, "the first-use voice choice must not hold playback (#286)")
        // Exercise the real source adapter: nativeMediaId is an asset ID, not a URL.
        let started = try await waitForSourceProgress(model: model, player: sourcePlayer, toMs: 200)
        XCTAssertGreaterThan(sourcePlayer.currentMediaTimeMs() ?? 0, 100, "Source audio must actually advance before Skim: \(started)")
        model.pause()
        let pausedTime = sourcePlayer.currentMediaTimeMs() ?? 0
        model.resumePlayback()
        let resumed = try await waitForSourceProgress(model: model, player: sourcePlayer, toMs: pausedTime + 200)
        XCTAssertGreaterThan(sourcePlayer.currentMediaTimeMs() ?? 0, pausedTime + 100, "Resume must play on: \(resumed)")
        XCTAssertTrue(model.snapshot.canSkimForward)
        XCTAssertEqual(model.skimForwardDestinationMs, 5_000)
        XCTAssertEqual(model.skimForwardTitle, "Skim to 0:05")
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
        XCTAssertEqual(model.skimForwardDestinationMs, model.snapshot.skimBridgeState?.destinationMediaTimeMs)
        model.skimForward()
        XCTAssertNil(model.snapshot.skimBridgeState, "Second Skim tap exits instead of restarting or chaining a summary")
        for _ in 0..<500 where model.snapshot.skimBridgeState != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.snapshot.skimBridgeState)
        // Crossing the test Margin opens Companion's intentional pause.
        // The wait dismisses it just as the listener would before expecting progress.
        let returned = try await waitForSourceProgress(model: model, player: sourcePlayer, toMs: 5_200)
        XCTAssertGreaterThan(sourcePlayer.currentMediaTimeMs() ?? 0, 5_100, "Skim must return to progressing source audio: status=\(model.snapshot.status), failure=\(model.snapshot.lastFailure ?? "none"), pending=\(model.pendingImportedCommentary != nil), \(returned)")
        model.pause()
        // While paused, a map change can move where Skim Back lands without flipping availability.
        // The Lock Screen must show the new time, not the one from before the change (#115).
        XCTAssertTrue(model.snapshot.canSkimBackward)
        XCTAssertEqual(model.gate2CompactSnapshot?.skimBackwardDestinationMs, 5_000, "precondition: the Lock Screen shows Skim Back's destination")
        func movedMap(sceneOneStartMs: Int) -> PortableListeningMapProposalArtifact {
            let bounds = [0, sceneOneStartMs, 10_000]
            return PortableListeningMapProposalArtifact(id: proposal.id, createdAt: proposal.createdAt, generator: "test", scenes: (0..<2).map { index in
                PortableListeningMapScene(id: "scene-\(index)", order: index, title: "Scene \(index)", summaryText: "A short recap.", summaryAssetId: "supplied-summary", summaryProvenance: .modelGenerated, eligibility: .eligible, startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: bounds[index]), endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: bounds[index + 1]))
            })
        }
        try store.savePortableListeningMapProposal(movedMap(sceneOneStartMs: 4_000), itemId: item.id)
        model.refreshSkimAvailabilityForTesting()
        XCTAssertTrue(model.snapshot.canSkimBackward)
        XCTAssertEqual(model.skimBackwardDestinationMs, 4_000)
        XCTAssertEqual(model.gate2CompactSnapshot?.skimBackwardDestinationMs, 4_000, "a destination-only change must reach the Lock Screen")
        try store.savePortableListeningMapProposal(movedMap(sceneOneStartMs: 5_000), itemId: item.id)
        model.refreshSkimAvailabilityForTesting()
        XCTAssertEqual(model.gate2CompactSnapshot?.skimBackwardDestinationMs, 5_000)
        // Reproduce a device update: the durable item URL points at a former
        // container, while the owned asset remains under the current support root.
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
        let relocated = try await waitForSourceProgress(model: reconstructed, player: resumedPlayer, toMs: resumedAt + 200)
        XCTAssertGreaterThan(resumedPlayer.currentMediaTimeMs() ?? 0, resumedAt + 100, "Saved-session playback must survive container relocation: \(relocated)")
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

    // MARK: A friend's shared map on a downloaded podcast copy (#481)

    func testSharedMapOnTheSameDownloadedEditionBecomesTheItemsMap() async throws {
        let fixture = try await importSharedPodcastMap(senderEdition: .sameAsRecipient, listenerMap: .none)
        defer { fixture.cleanup() }
        let projection = try XCTUnwrap(fixture.store.loadResolvedListeningMapProjection(itemId: fixture.itemId))
        XCTAssertEqual(projection.proposalId, "friend-map", "Skim reads this projection and the layer's proposal")
        XCTAssertEqual(projection.projectedRecipientTime(for: 5_000), 5_000)
        XCTAssertNil(fixture.model.sharedListeningMapRefusal(itemId: fixture.itemId))
    }

    func testSkimFollowsASharedMapOnTheSameDownloadedEdition() async throws {
        let fixture = try await importSharedPodcastMap(senderEdition: .sameAsRecipient, listenerMap: .none, summaries: true)
        defer { fixture.cleanup() }
        let model = fixture.model
        model.openItem(id: fixture.itemId)
        XCTAssertEqual(model.selectedItem.listeningMapScenes.map(\.startMs), [0, 5_000], "The item lists the friend's scenes")
        // The summaries render through the injected preparation job once the map is placed.
        func bridgeCount() -> Int {
            ((try? fixture.store.loadOwnedOfflineAssets()) ?? [])
                .filter { $0.itemId == fixture.itemId && $0.category == .summaryBridge && $0.integrity == .valid }.count
        }
        for _ in 0..<500 where bridgeCount() < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(bridgeCount(), 2, "One summary per eligible scene")
        model.startItem(id: fixture.itemId)
        let player = try XCTUnwrap(fixture.sourcePlayer)
        let started = try await waitForSourceProgress(model: model, player: player, toMs: 200)
        XCTAssertGreaterThan(player.currentMediaTimeMs() ?? 0, 100, "The downloaded copy must actually play before Skim: \(started)")
        for _ in 0..<150 where !model.snapshot.canSkimForward { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.snapshot.canSkimForward, "Skim uses the friend's map and its summaries")
        XCTAssertEqual(model.skimForwardDestinationMs, 5_000)
        model.skimForward()
        XCTAssertEqual(model.snapshot.skimBridgeState?.destinationMediaTimeMs, 5_000, "Skim heads for the friend's next scene")
        model.pause()
    }

    func testSharedMapNeverReplacesTheListenersOwnMap() async throws {
        let fixture = try await importSharedPodcastMap(senderEdition: .sameAsRecipient, listenerMap: .own)
        defer { fixture.cleanup() }
        let projection = try XCTUnwrap(fixture.store.loadResolvedListeningMapProjection(itemId: fixture.itemId))
        XCTAssertEqual(projection.id, "my-projection")
        XCTAssertEqual(projection.proposalId, "my-map")
        XCTAssertEqual(try fixture.store.loadPortableListeningMapProposals(itemId: fixture.itemId).map(\.id), ["my-map"])
    }

    func testSharedMapNeverReplacesThePublishersChapters() async throws {
        let fixture = try await importSharedPodcastMap(senderEdition: .sameAsRecipient, listenerMap: .publisherChapters)
        defer { fixture.cleanup() }
        XCTAssertNil(try fixture.store.loadResolvedListeningMapProjection(itemId: fixture.itemId),
                     "The publisher's chapters stay the item's map")
        XCTAssertNil(fixture.model.sharedListeningMapRefusal(itemId: fixture.itemId))
    }

    func testSharedMapThatCannotBePlacedOnYourCopySaysWhy() async throws {
        let fixture = try await importSharedPodcastMap(senderEdition: .differentWithoutEvidence, listenerMap: .none)
        defer { fixture.cleanup() }
        XCTAssertEqual(
            fixture.model.sharedListeningMapRefusal(itemId: fixture.itemId),
            "The shared map has no audio to match near scene 1 (Opening)."
        )
        let reopened = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: fixture.databaseURL)
        reopened.bootstrapLibraryIfNeeded()
        XCTAssertEqual(reopened.sharedListeningMapRefusal(itemId: fixture.itemId),
                       "The shared map has no audio to match near scene 1 (Opening).", "The reason survives a restart")
        XCTAssertNil(try fixture.store.loadResolvedListeningMapProjection(itemId: fixture.itemId)?.proposalId,
                     "A refused map is never activated")
    }

    /// Waits for the source to play on to `toMs` the way a listener waits: on the player, not on a fixed time (#835).
    ///
    /// A fixed 3 s window failed under load: the source sat at exactly its start or Skim destination with the
    /// session playing. AVPlayer reports playing before its clock moves, because the audio output takes time to
    /// start (about 0.4–0.7 s on the Mac host, measured for #835; `StreamSeekLifecycleTests` prints it).
    /// A loaded simulator, whose audio I/O logs "skipping cycle due to overload", stretched that past the window. After Skim the window also held the
    /// summary player's stop, the resume, and possibly Companion's pause and its dismissal.
    ///
    /// So the clock's allowance starts only once the session is playing again (no Skim summary, no Companion pause
    /// waiting) and the player itself reports playing, with no seek pending. Companion's pause is dismissed as the
    /// listener would. A source that never gets back to playing, or whose clock never moves once it does, still fails.
    /// Returns what was observed, for assertion messages.
    private func waitForSourceProgress(
        model: Gate1AppModel,
        player: AVPlayerStreamPlaybackClient,
        toMs target: Int,
        toStartPlaying: Duration = .seconds(15),
        toAdvanceOncePlaying: Duration = .seconds(10)
    ) async throws -> String {
        let clock = ContinuousClock()
        let began = clock.now
        var playingSince: ContinuousClock.Instant?
        var lastState = "not sampled"
        while (player.currentMediaTimeMs() ?? 0) < target {
            if model.pendingImportedCommentary != nil { model.dismissPendingImportedCommentary() }
            let transport = model.snapshot.targetId.flatMap { player.playbackTransportState(targetId: $0) }
            let playing = model.snapshot.skimBridgeState == nil
                && model.pendingImportedCommentary == nil
                && model.snapshot.status.isPlaybackActive
                && transport == .playing
            let now = clock.now
            lastState = "session \(model.snapshot.status), player \(transport.map { "\($0)" } ?? "none"), skim \(model.snapshot.skimBridgeState == nil ? "off" : "on")"
            if playing {
                let since = playingSince ?? now
                playingSince = since
                if now - since > toAdvanceOncePlaying { break }
            } else {
                playingSince = nil
                if now - began > toStartPlaying { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let waited = clock.now - began
        let playedFor = playingSince.map { clock.now - $0 }
        return "clock \(player.currentMediaTimeMs() ?? -1) ms after \(waited.formatted(.units(allowed: [.milliseconds]))); "
            + "player reported playing for \(playedFor?.formatted(.units(allowed: [.milliseconds])) ?? "none"); last \(lastState)"
    }

    private enum SenderEdition { case sameAsRecipient, differentWithoutEvidence }
    private enum ListenerMap { case none, own, publisherChapters }

    private struct SharedPodcastMapFixture {
        let model: Gate1AppModel
        let store: SQLiteSessionStore
        let itemId: String
        let databaseURL: URL
        let sourcePlayer: AVPlayerStreamPlaybackClient?
        let cleanup: () -> Void
    }

    /// Imports a real packet carrying a friend's map onto a podcast the listener has downloaded,
    /// through the same import and download paths the app uses, and waits for anchor resolution.
    /// With `summaries`, the scenes carry summaries, an injected job renders them, and the copy plays for real.
    private func importSharedPodcastMap(
        senderEdition: SenderEdition,
        listenerMap: ListenerMap,
        summaries: Bool = false
    ) async throws -> SharedPodcastMapFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "shared-podcast-map-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = root.appending(path: "library.sqlite")
        let seeding = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db)
        seeding.resetAndSeed()
        let store = try SQLiteSessionStore(path: db.path)
        let item = Item(
            id: "shared-map-episode", title: "Shared Map Episode",
            mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: "https://example.com/episodes/shared-map", status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/shared-map.m4a", durationMs: 10_000)
        )
        try store.saveItem(item)
        // The listener's downloaded copy, where the download coordinator keeps it.
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let fileName = "shared-map-\(UUID().uuidString).m4a"
        let download = support.appending(path: "PodcastAudio/\(fileName)")
        try FileManager.default.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writeSummaryAudio(to: download, seconds: 10)
        let downloadBytes = try Data(contentsOf: download)
        try store.savePodcastDownload(PodcastDownloadRecord(
            id: "download-\(item.id)", itemId: item.id, remoteURL: "https://cdn.example.com/shared-map.m4a",
            localRelativePath: fileName, state: .availableOffline, bytesWritten: Int64(downloadBytes.count)
        ))
        if listenerMap == .publisherChapters {
            try store.saveTranscriptTimeline(SourceTranscriptTimeline(
                id: "publisher-timeline", itemId: item.id, createdAt: Date(),
                timeline: TranscriptTimeline(segments: [], chapters: [
                    MediaTimelineChapter(id: "chapter-1", title: "Cold open", startMs: 0, transcriptSegmentId: "segment-1")
                ], durationMs: 10_000)
            ))
        }
        if listenerMap == .own {
            try store.savePortableListeningMapProposal(PortableListeningMapProposalArtifact(
                id: "my-map", createdAt: Date(), generator: "test",
                scenes: [PortableListeningMapScene(id: "mine", order: 0, eligibility: .eligible,
                    startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 0),
                    endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 10_000))]
            ), itemId: item.id)
            try store.saveResolvedListeningMapProjection(EpisodeFingerprintAlignment.makeProjection(
                id: "my-projection", itemId: item.id, proposalId: "my-map",
                recipientEditionSHA256: try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: download),
                matches: [], exactEdition: true
            ))
        }

        let sourcePlayer = summaries ? AVPlayerStreamPlaybackClient() : nil
        let model = Gate1AppModel(
            audioPlaybackClient: sourcePlayer.map { RoutedAudioPlaybackClient(speech: NoopAudioPlaybackClient(), media: $0) }
                ?? NoopAudioPlaybackClient(),
            preparedTextAudioPrewarmHandler: { itemId, _, text, directory, _, _ in
                let url = directory.appending(path: "\(itemId).m4a")
                do { try Self.writeSummaryAudio(to: url) } catch { return .failure(error) }
                return .success(PreparedTextAudio(
                    normalizedText: text,
                    media: ItemMedia(sourceType: .generatedTTSPrerendered, url: url.absoluteString, durationMs: 1_000),
                    timeline: TranscriptTimeline(segments: [], chapters: [], durationMs: 1_000)
                ))
            },
            databaseURLOverride: db
        )
        model.bootstrapLibraryIfNeeded()
        // The improved voice waits on a first-use choice; summaries then render in the system voice (#286).
        if summaries { model.declineCurrentTerms() }
        let senderDigest = senderEdition == .sameAsRecipient
            ? try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: download)
            : String(repeating: "5", count: 64)
        let spine = EditionFingerprintSpineArtifact(
            id: "friend-spine", itemId: "friend-episode",
            producingEditionDurationMs: 10_000, producingEditionSHA256: senderDigest, landmarks: []
        )
        let proposal = PortableListeningMapProposalArtifact(
            id: "friend-map", createdAt: Date(), generator: "test",
            scenes: (0..<2).map { index in
                PortableListeningMapScene(
                    id: "friend-scene-\(index)", order: index, title: index == 0 ? "Opening" : "Close",
                    summaryText: summaries ? "A short recap." : nil, summaryProvenance: summaries ? .modelGenerated : nil,
                    eligibility: summaries ? .eligible : .unknown,
                    startAnchor: PortableAnchorEvidence(anchorType: .transcript, mediaTimeMs: index * 5_000),
                    endAnchor: PortableAnchorEvidence(anchorType: .transcript, mediaTimeMs: (index + 1) * 5_000)
                )
            }
        )
        let revision = InterjectionShareRevision(id: "revision", interjectionId: "margin", itemId: "friend-episode", sessionId: "friend-session", createdAt: Date(), approvedTranscript: "Listen to this part.", anchorBefore: "", anchorAfter: "", status: .senderApproved)
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "shared-podcast-map", createdAt: Date(), item: SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: nil),
            itemTransportSelection: .reference,
            selections: [ReviewedInterjectionSelection(packageScopedId: "friend-margin", revision: revision, anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 2_000), representation: .textOnly)],
            mapProposals: [proposal], fingerprintSpines: [spine], senderDisplayLabel: "Friend"
        )
        let url = root.appending(path: "friend.spokenmargins")
        _ = try SpokenMarginsPackageArchive.write(prepared, to: url)
        model.handleIncomingURL(url)
        XCTAssertEqual(model.spokenMarginsPackageImportReview?.matchingItemId, item.id)
        model.confirmSpokenMarginsPackageImport()
        for _ in 0..<250 where model.isImportingSpokenMarginsPackage { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.spokenMarginsPackageImportError)
        let key = "importedPodcastAnchorResolution:\(item.id)"
        for _ in 0..<500 where model.diagnostics[key]?.hasPrefix("complete") != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.diagnostics[key]?.hasPrefix("complete"), true, model.diagnostics[key] ?? "never scheduled")
        return SharedPodcastMapFixture(model: model, store: store, itemId: item.id, databaseURL: db, sourcePlayer: sourcePlayer) {
            try? FileManager.default.removeItem(at: download)
            try? FileManager.default.removeItem(at: root)
        }
    }

    nonisolated private static func writeSummaryAudio(to url: URL, seconds: Int = 1) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(24_000 * seconds)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { channel[i] = sin(Float(i) * 0.03) * 0.02 }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        try file.write(from: buffer)
    }
}
