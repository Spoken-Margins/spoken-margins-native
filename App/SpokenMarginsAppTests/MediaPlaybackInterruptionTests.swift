import AVFoundation
import SessionKit
import SessionKitAudio
import XCTest
import SessionKitPersistence
import MediaPlayer
@testable import SpokenMarginsApp

@MainActor
final class MediaPlaybackInterruptionTests: XCTestCase {
    // The AudioAdapters plan runs on a simulator with the app's data removed,
    // so the first-use voice choice is still pending and startItem() waits on
    // the terms sheet, leaving the model idle (#599). Every test starts with
    // the choice a listener makes when they keep the iOS voice, as in
    // SourceLinkImportTests (#446).
    private static let firstUseVoiceKeys = [
        "supertonicTTSMigrationV1",
        "supertonicVoicePendingTermsV1",
        "ttsMode",
        "ttsVoiceSelection",
        SpokenMarginsTerms.acceptanceVersionKey,
        SpokenMarginsTerms.acceptanceDateKey
    ]
    private var priorFirstUseVoiceDefaults: [String: Any] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let defaults = UserDefaults.standard
        priorFirstUseVoiceDefaults = [:]
        for key in Self.firstUseVoiceKeys {
            priorFirstUseVoiceDefaults[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
        // What declineCurrentTerms() leaves behind after the pre-1.0 migration.
        defaults.set(true, forKey: "supertonicTTSMigrationV1")
        defaults.set(AppTTSVoiceSelection.system.rawValue, forKey: "ttsVoiceSelection")
        defaults.set("systemImmediate", forKey: "ttsMode")
    }

    override func tearDownWithError() throws {
        let defaults = UserDefaults.standard
        for key in Self.firstUseVoiceKeys {
            if let value = priorFirstUseVoiceDefaults[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try super.tearDownWithError()
    }

    func testResumePreservesMatchingPendingNavigationSeek() async throws {
        let audioURL = try makeTestWAV(duration: 10)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let client = AVPlayerStreamPlaybackClient()
        defer { try? client.stop() }
        let target = "seek-resume-source"
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "seek-resume", targetType: .transcriptBackedMedia,
            targetId: target, title: "Seek then resume",
            playbackURL: audioURL.absoluteString, durationMs: 10_000
        ))
        try client.play(targetId: target, fromMediaTimeMs: 0)
        for _ in 0..<150 where (client.currentMediaTimeMs() ?? 0) < 200 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(client.currentMediaTimeMs() ?? 0, 100)
        try client.pause()
        let request = try client.requestMediaSeek(toMediaTimeMs: 5_000)
        XCTAssertEqual(client.mediaSeekResolution(for: request), .pending)
        // No suspension here: resume arrives before the navigation callback.
        try client.play(targetId: target, fromMediaTimeMs: 5_000)
        XCTAssertEqual(client.mediaSeekResolution(for: request), .pending,
                       "Resume at the same destination must retain the navigation transaction")
        for _ in 0..<150 where client.mediaSeekResolution(for: request) == .pending {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .accepted(let acceptedTime) = client.mediaSeekResolution(for: request) else {
            return XCTFail("Matching seek was not accepted: \(client.mediaSeekResolution(for: request))")
        }
        XCTAssertEqual(acceptedTime, 5_000, accuracy: 250)
        for _ in 0..<150 where (client.currentMediaTimeMs() ?? 0) < 5_300 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(client.currentMediaTimeMs() ?? 0, 5_100)
        // A genuinely different destination must still supersede the old one.
        let replaced = try client.requestMediaSeek(toMediaTimeMs: 2_000)
        try client.play(targetId: target, fromMediaTimeMs: 3_000)
        guard case .failed(_, let reason) = client.mediaSeekResolution(for: replaced) else {
            return XCTFail("A different destination must replace the old navigation request")
        }
        XCTAssertEqual(reason, "media_seek_superseded")
    }

    func testLoadedPlayerDurationReplacesUnderestimatedFeedDuration() async throws {
        let audioURL = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let client = AVPlayerStreamPlaybackClient()
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "duration-correction",
            targetType: .transcriptBackedMedia,
            targetId: "duration-correction-audio",
            title: "Duration correction",
            playbackURL: audioURL.absoluteString,
            durationMs: 1_000
        ))

        try client.play(targetId: "duration-correction-audio", fromMediaTimeMs: 0)
        for _ in 0..<100 where client.currentPlaybackDurationMs() != 3_000 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(client.currentPlaybackDurationMs(), 3_000)
        try client.stop()
    }

    func testPreparedTextMediaPublishesCanonicalPauseAndConditionalResumeIntent() async throws {
        let audioURL = try makeTestWAV(duration: 2)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let notificationCenter = NotificationCenter()
        let events = InterruptionEventRecorder()
        let began = expectation(description: "interruption began")
        let ended = expectation(description: "interruption ended with resume permission")
        let client = AVPlayerStreamPlaybackClient(
            audioSessionNotificationCenter: notificationCenter,
            interruptionHandler: { event in
                events.append(event)
                switch event {
                case .began:
                    began.fulfill()
                case .endedShouldResume:
                    ended.fulfill()
                }
            }
        )
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "native-text",
            targetType: .transcriptBackedMedia,
            targetId: "prepared-native-text-audio",
            title: "Prepared native text",
            playbackURL: audioURL.absoluteString,
            durationMs: 2_000
        ))
        try client.play(targetId: "prepared-native-text-audio", fromMediaTimeMs: 0)

        notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        )
        await fulfillment(of: [began], timeout: 1)
        XCTAssertEqual(client.playbackTransportState(targetId: "prepared-native-text-audio"), .paused)

        notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )
        await fulfillment(of: [ended], timeout: 1)
        XCTAssertEqual(events.values, [.began, .endedShouldResume])
        try client.stop()
    }

    func testImportedMarginTransportFreezesAndResumesRealSourceAndMarginPlayers() async throws {
        try await verifyImportedMarginTransport(nativeMedia: true, guided: false)
    }

    func testGuidedTextMarginTransportRetainsSourcePauseUntilExplicitReturn() async throws {
        try await verifyImportedMarginTransport(nativeMedia: false, guided: true)
    }

    private func verifyImportedMarginTransport(nativeMedia: Bool, guided: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "margin-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try makeTestWAV(duration: 30)
        let marginURL = try makeTestWAV(duration: 30)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: marginURL)
        }
        let db = root.appending(path: "library.sqlite")
        let sourcePlayer = AVPlayerStreamPlaybackClient()
        let routed = RoutedAudioPlaybackClient(speech: NoopAudioPlaybackClient(), media: sourcePlayer)
        let model = Gate1AppModel(audioPlaybackClient: routed, databaseURLOverride: db)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: db.path)
        let itemID = nativeMedia ? "real-source" : "item-pill"
        if nativeMedia {
            try store.seed(item: Item(id: itemID, title: "Real source", mediaType: "audiobook", text: nil,
                externalReference: sourceURL.absoluteString, status: "ready", externalReferenceType: "audiobook",
                media: ItemMedia(sourceType: .nativeMediaFile, url: sourceURL.absoluteString, durationMs: 30_000, nativeMediaId: "source-audio")))
        }
        model.startItem(id: itemID)
        defer { model.returnToSourceFromImportedCommentary(); model.pause() }
        if nativeMedia {
            for _ in 0..<150 where (sourcePlayer.currentMediaTimeMs() ?? 0) < 200 { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertGreaterThan(sourcePlayer.currentMediaTimeMs() ?? 0, 100)
        }
        let layer = ImportedCommentaryLayer(id: "received", itemId: itemID, packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: nativeMedia ? .other : .text, title: "Source"),
            displayLabel: "Reviewer", importedAt: Date(), sourceResolutionStatus: .resolved,
            isEnabled: true, isMuted: true, revealMode: guided ? .guided : .companion)
        let record = ImportedCommentaryInterjection(id: "note", layerId: layer.id, packageScopedId: "note", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: nativeMedia ? .media : .text),
            approvedTranscript: "Reviewed words", audioPath: marginURL.path, audioDurationMs: 30_000,
            resolution: ImportedAnchorResolution(evidenceClass: nativeMedia ? .acousticVerified : .articleTextVerified,
                localStartChar: nativeMedia ? nil : 120, localEndChar: nativeMedia ? nil : 140,
                localMediaTimeMs: nativeMedia ? 1_000 : nil, confidence: 1))
        model.selectedItem.importedCommentaryLayers = [layer]
        model.selectedItem.importedCommentaryInterjections = [layer.id: [record]]
        if guided {
            XCTAssertTrue(model.handleGate2CompactApplicationCommand(Gate2CompactApplicationCommand.jumpToSharedMargin, targetID: record.id))
            for _ in 0..<150 where model.playingImportedCommentary == nil { try await Task.sleep(for: .milliseconds(20)) }
        } else {
            model.listenToImportedCommentary(layerID: layer.id, interjectionID: record.id)
        }
        let player = try XCTUnwrap(Mirror(reflecting: model).children.first { $0.label == "interjectionAudioPlayer" }?.value as? AVPlayer)
        for _ in 0..<150 where player.currentTime().seconds < 0.2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(player.currentTime().seconds, 0.1)
        XCTAssertEqual(model.snapshot.status, .paused)
        let sourcePausedAt = sourcePlayer.currentMediaTimeMs() ?? 0
        model.playPause()
        XCTAssertTrue(model.importedCommentaryIsPaused)
        XCTAssertFalse(model.activePlaybackIsPlaying)
        XCTAssertEqual(player.rate, 0)
        let marginPausedAt = player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.currentTime().seconds, marginPausedAt, accuracy: 0.03)
        XCTAssertLessThanOrEqual(abs((sourcePlayer.currentMediaTimeMs() ?? 0) - sourcePausedAt), 30)
        XCTAssertEqual(model.playingImportedCommentary?.id, record.id)
        model.dispatchGate2CompactCommand(.play, origin: "imported_margin_remote")
        for _ in 0..<150 where player.currentTime().seconds < marginPausedAt + 0.2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(player.currentTime().seconds, marginPausedAt + 0.1)
        XCTAssertEqual(model.snapshot.status, .paused)
        model.dispatchGate2CompactCommand(.pause, origin: "imported_margin_remote")
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(model.importedCommentaryIsPaused)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Shared Margin")
        model.resumePlayback()
        model.pause()
        XCTAssertEqual(player.rate, 0, "Explicit pause must control the Margin too")
        if guided {
            // Natural completion uses the same once-only source restoration as Return.
            model.resumePlayback()
            await player.seek(to: CMTime(seconds: 29.8, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            for _ in 0..<150 where model.playingImportedCommentary != nil { try await Task.sleep(for: .milliseconds(20)) }
        } else {
            model.returnToSourceFromImportedCommentary()
        }
        XCTAssertNil(model.playingImportedCommentary)
        XCTAssertNil(player.currentItem)
        for _ in 0..<150 where model.snapshot.status == .starting { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.snapshot.status, .playing)
        if nativeMedia {
            for _ in 0..<150 where (sourcePlayer.currentMediaTimeMs() ?? 0) < sourcePausedAt + 200 { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertGreaterThan(sourcePlayer.currentMediaTimeMs() ?? 0, sourcePausedAt + 100)
        }
        model.pause()
        model.returnToSourceFromImportedCommentary()
        XCTAssertEqual(model.snapshot.status, .paused, "Repeated return cannot resume twice")
        model.selectedItem.importedCommentaryLayers = [layer]
        model.selectedItem.importedCommentaryInterjections = [layer.id: [record]]
        model.listenToImportedCommentary(layerID: layer.id, interjectionID: record.id)
        XCTAssertNotNil(model.playingImportedCommentary)
        model.stopInterjectionAudioPlayback()
        model.returnToSourceFromImportedCommentary()
        XCTAssertEqual(model.snapshot.status, .paused, "A stopped Margin must not retain a source-resume intent")
    }

    /// #469: a shared Margin is new until its voice first plays, by any route. This route is
    /// Listen in the Margins list or the Timeline's shared Margin sheet.
    func testListeningToASharedMarginMarksItHeardOnce() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "item-pill", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        XCTAssertEqual(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id }?.isNew, true, "new until heard")
        XCTAssertNil(try fixture.storedRecord()?.firstHeardAt)

        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        XCTAssertNotNil(model.playingImportedCommentary)
        try waitUntil("its voice plays") { try fixture.storedRecord()?.firstHeardAt != nil }
        let heardAt = try XCTUnwrap(try fixture.storedRecord()?.firstHeardAt, "hearing it records the time")
        XCTAssertEqual(model.selectedItem.importedCommentaryInterjections[fixture.layer.id]?.first?.isNewToListener, false)
        XCTAssertEqual(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id }?.isNew, false, "the mark goes away")

        model.stopInterjectionAudioPlayback()
        model.returnToSourceFromImportedCommentary()
        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        model.stopInterjectionAudioPlayback()
        XCTAssertEqual(try fixture.storedRecord()?.firstHeardAt, heardAt, "a second play keeps the first time")
        model.refreshMarginRows()
        XCTAssertEqual(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id }?.isNew, false, "stays gone after a reload")
    }

    /// #690: Listen asks AVPlayer to play, but a voice file that can't be decoded never plays,
    /// so the shared Margin stays new. It used to be marked heard as soon as play was asked.
    func testASharedMarginWhoseVoiceFailsToPlayStaysNew() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "item-pill", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        try Data("not audio".utf8).write(to: URL(fileURLWithPath: fixture.record.audioPath!))
        let model = fixture.model
        model.refreshMarginRows()
        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertNil(try fixture.storedRecord()?.firstHeardAt, "a voice that never played isn't heard")
        model.stopInterjectionAudioPlayback()
        model.refreshMarginRows()
        XCTAssertEqual(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id }?.isNew, true)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// #469: the Timeline's Margin moment for a shared podcast Margin (#158) marks it heard when its voice starts.
    func testPlayingASharedMarginsMomentMarksItHeard() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })
        XCTAssertTrue(row.isNew)

        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertNil(try fixture.storedRecord()?.firstHeardAt, "the lead-in alone isn't hearing it")
        model.playMarginMomentNow()
        XCTAssertNotNil(try fixture.storedRecord()?.firstHeardAt, "its voice started")
        XCTAssertEqual(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id }?.isNew, false)
    }

    private func makeTestWAV(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "media-interruption-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frameCount = AVAudioFrameCount(44_100 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

private final class InterruptionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AudioPlaybackInterruptionEvent] = []

    var values: [AudioPlaybackInterruptionEvent] {
        lock.withLock { storage }
    }

    func append(_ event: AudioPlaybackInterruptionEvent) {
        lock.withLock {
            storage.append(event)
        }
    }
}

/// A native-media item with one shared podcast Margin whose voice is a real WAV file (#469).
@MainActor
private struct SharedMarginHearingFixture {
    let model: Gate1AppModel
    let store: SQLiteSessionStore
    let layer: ImportedCommentaryLayer
    let record: ImportedCommentaryInterjection
    private let root: URL
    private let files: [URL]

    init(itemID: String, makeWAV: (TimeInterval) throws -> URL) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "margin-heard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = try makeWAV(30)
        let voiceURL = try makeWAV(2)
        files = [sourceURL, voiceURL]
        let db = root.appending(path: "library.sqlite")
        let routed = RoutedAudioPlaybackClient(speech: NoopAudioPlaybackClient(), media: AVPlayerStreamPlaybackClient())
        model = Gate1AppModel(audioPlaybackClient: routed, databaseURLOverride: db)
        model.resetAndSeed()
        store = try SQLiteSessionStore(path: db.path)
        if itemID == "real-source" {
            try store.seed(item: Item(id: itemID, title: "Real source", mediaType: "audiobook", text: nil,
                externalReference: sourceURL.absoluteString, status: "ready", externalReferenceType: "audiobook",
                media: ItemMedia(sourceType: .nativeMediaFile, url: sourceURL.absoluteString, durationMs: 30_000, nativeMediaId: "source-audio")))
        }
        layer = ImportedCommentaryLayer(id: "received", itemId: itemID, packageDigest: "digest-\(UUID().uuidString)", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Source"),
            displayLabel: "Reviewer", importedAt: Date(), sourceResolutionStatus: .resolved,
            isEnabled: true, isMuted: true, revealMode: .companion)
        record = ImportedCommentaryInterjection(id: "note", layerId: layer.id, packageScopedId: "note", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media),
            approvedTranscript: "Reviewed words", audioPath: voiceURL.path, audioDurationMs: 2_000,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 1_000, confidence: 1))
        _ = try store.importCommentaryLayer(layer, interjections: [record])
        model.selectedItem.importedCommentaryLayers = [layer]
        model.selectedItem.importedCommentaryInterjections = [layer.id: [record]]
    }

    func storedRecord() throws -> ImportedCommentaryInterjection? {
        try store.loadImportedCommentaryInterjections(layerId: layer.id).first { $0.id == record.id }
    }

    func cleanUp() {
        model.stopInterjectionAudioPlayback()
        for url in files + [root] { try? FileManager.default.removeItem(at: url) }
    }
}
