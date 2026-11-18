import AVFoundation
import XCTest
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SessionKitSharing
@testable import SpokenMarginsApp

/// #122: the owner's phone was killed for memory twice, going from a podcast with shared Margins to an article.
///
/// This is the issue's measured run, sized for a lane test (180 s at most). A podcast the listener downloaded gets a
/// friend's packet of shared Margins through the real import, then playback moves podcast → article four times and back
/// three times, each playing for real: the podcast in the app's own AVPlayer, the article in the voice under test. A
/// `MemoryFootprintRecorder` watches the model the way the app's own does and reads the real footprint at each switch.
/// The test prints the samples and the verdict (`MemoryFootprintVerdict`), the numbers #122 asks for, and fails when
/// memory stays behind at each switch.
///
/// What it can't show: growth per minute over the issue's 10-minute article, which `memoryVerdict` in the owner's
/// Diagnostics reports from real listening; the phone's own memory limit; and anything the simulator's memory
/// accounting does differently from a device.
@MainActor
final class PodcastToArticleMemoryTests: XCTestCase {
    /// The iOS voice, which reads articles on a fresh install and in the simulator.
    func testSwitchingFromASharedMarginPodcastToAnArticleOnTheIOSVoiceLeavesNoMemoryBehind() async throws {
        executionTimeAllowance = 180
        try await SystemVoiceRuntime.requireAnsweringVoice() // loads the speech service before the clock starts
        let model = try await makeModelWithSharedPodcast()
        try await runSwitches(model, voice: "iOS voice", secondsEach: 6)
    }

    /// Supertonic, the downloaded voice the owner listens with, and the app's biggest memory user on the phone
    /// (206 → 540 MB while it read, #122 comment of 2026-10-04). The model is a download: the lane provides it when
    /// `SupertonicSpeechTests/testDownloadedRendererSynthesizesJamesAndLilyAndReusesSessions` is in the same run.
    func testSwitchingFromASharedMarginPodcastToAnArticleOnSupertonicLeavesNoMemoryBehind() async throws {
        executionTimeAllowance = 180
        let real = try SupertonicTestAssets.realModel()
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        // The app reads the last version folder under Voices/supertonic-3-int8; this name sorts last.
        let installed = VoiceCatalogCoordinator.voicesRoot(supportDirectory: support)
            .appending(path: SupertonicAssetResolver.catalogVoiceId, directoryHint: .isDirectory)
            .appending(path: "zzzz-memory-scenario", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: installed)
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: real.rootURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: installed) }
        let defaults = StandardDefaultsSnapshot(keys: [
            SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey, "supertonicTTSMigrationV1",
            Gate1AppModel.supertonicVoicePendingTermsKey, "ttsVoiceSelection", "ttsMode",
        ])
        addTeardownBlock { defaults.restore() }
        SpokenMarginsTerms.recordAcceptance()

        let model = try await makeModelWithSharedPodcast()
        model.ttsVoiceSelection = .james
        model.ttsVoiceSelectionChanged()
        XCTAssertTrue(model.speechPlaybackClient is SupertonicSpeechPlaybackClient, "the article must be read by Supertonic")
        try await runSwitches(model, voice: "Supertonic", secondsEach: 6) {
            XCTAssertNil(model.diagnostics["supertonicFallback"], "Supertonic handed the article to another voice")
        }
    }

    // MARK: - The run

    private var podcastId = ""
    private var articleId = ""
    private var cleanup: [() -> Void] = []

    override func tearDown() {
        cleanup.reversed().forEach { $0() }
        cleanup = []
        super.tearDown()
    }

    /// Podcast first, then article, podcast, article, podcast, article, podcast, article: four switches into the
    /// article and three back, as in #122 item 3.
    private func runSwitches(
        _ model: Gate1AppModel,
        voice: String,
        secondsEach: Int,
        checkArticle: () -> Void = {}
    ) async throws {
        let recorder = MemoryFootprintRecorder(diagnostics: PinnedDiagnostics(diagnostics: RuntimeDiagnostics()), fileURL: nil)
        recorder.start(observing: model)
        try await play(podcastId, in: model, seconds: secondsEach)
        for round in 0..<4 {
            try await play(articleId, in: model, seconds: secondsEach)
            checkArticle()
            if round < 3 { try await play(podcastId, in: model, seconds: secondsEach) }
        }
        model.pause()

        let verdict = MemoryFootprintVerdict(samples: recorder.log.samples)
        let report = "#122 podcast → article, \(voice)\nmemoryFootprint: \(recorder.log.diagnosticsLine)\nmemoryVerdict: \(verdict.diagnosticsLine)"
        print(report)
        XCTContext.runActivity(named: "memory samples, \(voice)") { $0.add(XCTAttachment(string: report)) }
        XCTAssertEqual(recorder.log.samples.filter { $0.event == .itemSwitch }.count, 7,
                       "every switch is sampled, or the verdict reads too few: \(report)")
        if case .growingPerSwitch = verdict {
            XCTFail("memory stays behind at each switch; file the fix as its own issue with these numbers (#122 item 4). \(report)")
        }
    }

    /// Starts `itemId` and waits until it is really playing: the podcast's player clock moving, or the voice past the
    /// article's first characters. Then lets it play.
    private func play(_ itemId: String, in model: Gate1AppModel, seconds: Int) async throws {
        model.startItem(id: itemId)
        let isArticle = itemId == articleId
        func advanced() -> Bool {
            guard model.snapshot.itemId == itemId, model.snapshot.status == .playing else { return false }
            return isArticle ? (model.speechPlaybackClient?.currentCharOffset() ?? 0) > 0
                : (model.sessionAudioPlaybackClient?.currentMediaTimeMs() ?? 0) > 200
        }
        try await pollUntil(timeout: .seconds(30)) { advanced() }
        XCTAssertTrue(advanced(), "\(isArticle ? "the article" : "the podcast") never started playing: "
                      + "item \(model.snapshot.itemId ?? "none"), status \(model.snapshot.status)")
        try await Task.sleep(for: .seconds(seconds))
        XCTAssertEqual(model.snapshot.itemId, itemId)
        XCTAssertTrue(model.snapshot.status.isPlaybackActive, "playback stopped on its own: \(model.snapshot.status)")
    }

    /// A downloaded podcast, a friend's packet of shared Margins imported onto it through the real import, and a long
    /// article, in a fresh library whose model plays through the app's own clients.
    private func makeModelWithSharedPodcast() async throws -> Gate1AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "podcast-article-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cleanup.append { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db).resetAndSeed()
        let store = try SQLiteSessionStore(path: db.path)
        let podcast = Item(
            id: "memory-podcast", title: "Memory Podcast", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: "https://example.com/episodes/memory", status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/memory.m4a", durationMs: 120_000)
        )
        try store.saveItem(podcast)
        // The listener's downloaded copy, where the download coordinator keeps it.
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let fileName = "memory-\(UUID().uuidString).m4a"
        let download = support.appending(path: "PodcastAudio/\(fileName)")
        try FileManager.default.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
        cleanup.append { try? FileManager.default.removeItem(at: download) }
        try Self.writeEpisode(to: download, seconds: 120)
        try store.savePodcastDownload(PodcastDownloadRecord(
            id: "download-\(podcast.id)", itemId: podcast.id, remoteURL: "https://cdn.example.com/memory.m4a",
            localRelativePath: fileName, state: .availableOffline,
            bytesWritten: Int64(try Data(contentsOf: download).count)
        ))

        let model = Gate1AppModel(databaseURLOverride: db)
        model.bootstrapLibraryIfNeeded()

        let selections = (0..<3).map { index in
            ReviewedInterjectionSelection(
                packageScopedId: "friend-margin-\(index)",
                revision: InterjectionShareRevision(
                    id: "revision-\(index)", interjectionId: "margin-\(index)", itemId: "friend-episode",
                    sessionId: "friend-session", createdAt: Date(), approvedTranscript: "Listen to this part, number \(index).",
                    anchorBefore: "", anchorAfter: "", status: .senderApproved
                ),
                anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 20_000 + index * 30_000),
                representation: .textOnly
            )
        }
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "memory-shared-podcast", createdAt: Date(),
            item: SharedPacketItemMatcher.localIdentity(for: podcast, ownedAudiobookDigest: nil),
            itemTransportSelection: .reference, selections: selections, senderDisplayLabel: "Friend"
        )
        let packet = root.appending(path: "friend.spokenmargins")
        let manifest = try SpokenMarginsPackageArchive.write(prepared, to: packet)
        model.handleIncomingURL(packet)
        await model.waitForPackageStaging()
        XCTAssertEqual(model.spokenMarginsPackageImportReview?.matchingItemId, podcast.id)
        model.confirmSpokenMarginsPackageImport()
        try await pollUntil(timeout: .seconds(60)) {
            model.spokenMarginsPackageImportReview == nil && !model.isImportingSpokenMarginsPackage
        }
        XCTAssertNil(model.spokenMarginsPackageImportError)
        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: try XCTUnwrap(manifest.contentDigest)),
                                  "the shared Margins must be stored, as they were on the owner's phone")
        XCTAssertEqual(layer.itemId, podcast.id)

        model.importTitle = "A long article"
        model.importText = Self.longArticle
        model.importTextItem(startListening: false)
        articleId = try XCTUnwrap(model.libraryItems.first { $0.title == "A long article" }?.id)
        podcastId = podcast.id
        return model
    }

    /// About 6,000 words, far more than a test plays, so the voice never reaches the end.
    private static let longArticle = (1...300).map { paragraph in
        "Paragraph \(paragraph). A listener moves from a podcast to this article and back again. "
            + "Each sentence here is plain, so the voice reads it without pausing over names or numbers."
    }
    .joined(separator: "\n\n")

    private static func writeEpisode(to url: URL, seconds: Int) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(24_000 * seconds)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { channel[i] = sin(Float(i) * 0.03) * 0.02 }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
                                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        try file.write(from: buffer)
    }
}

private struct StandardDefaultsSnapshot {
    private let values: [String: Any]
    private let keys: [String]

    init(keys: [String]) {
        self.keys = keys
        values = keys.reduce(into: [:]) { values, key in values[key] = UserDefaults.standard.object(forKey: key) }
    }

    func restore() {
        for key in keys {
            if let value = values[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
