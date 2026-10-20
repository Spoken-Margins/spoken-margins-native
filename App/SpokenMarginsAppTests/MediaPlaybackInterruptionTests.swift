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

    // #1434: a backgrounded app with nothing playing can be suspended before iOS says the interruption is over,
    // so the owner's phone stayed paused after a message announcement. The client holds background time from the
    // interruption's start until the end arrives, or until the listener presses Play or Pause themselves.
    func testInterruptionHoldsBackgroundTimeUntilItEndsOrTheListenerActs() async throws {
        let audioURL = try makeTestWAV(duration: 4)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let notificationCenter = NotificationCenter()
        let probe = InterruptionHoldProbe()
        let client = AVPlayerStreamPlaybackClient(
            audioSessionNotificationCenter: notificationCenter,
            interruptionHold: probe.hold
        )
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "held-interruption", targetType: .transcriptBackedMedia,
            targetId: "held-interruption-audio", title: "Held interruption",
            playbackURL: audioURL.absoluteString, durationMs: 4_000
        ))
        try client.play(targetId: "held-interruption-audio", fromMediaTimeMs: 0)

        post(.began, to: notificationCenter)
        await settle { probe.begins == 1 }
        XCTAssertEqual(probe.begins, 1, "the app stays awake to hear the interruption end")
        XCTAssertEqual(probe.ends, 0)

        post(.ended, options: .shouldResume, to: notificationCenter)
        await settle { probe.ends == 1 }
        XCTAssertEqual(probe.ends, 1, "the time is given back once iOS reports the end")
        XCTAssertEqual(probe.hold.outcome, .ended)

        try client.play(targetId: "held-interruption-audio", fromMediaTimeMs: 0)
        post(.began, to: notificationCenter)
        await settle { probe.begins == 2 }
        XCTAssertEqual(probe.begins, 2)
        try client.play(targetId: "held-interruption-audio", fromMediaTimeMs: 500)
        XCTAssertEqual(probe.ends, 2, "the listener's own Play takes over before an end arrives")
        XCTAssertEqual(probe.hold.outcome, .listenerActed)
        try client.stop()
    }

    // #1434, owner's phone on 437fbc9: iOS sent no end after a message announcement. The player resumes once
    // the other audio stops, once, and not after the listener paused.
    func testInterruptionResumesWhenTheOtherAudioStopsWithoutAnEnd() async throws {
        let audioURL = try makeTestWAV(duration: 4)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let notificationCenter = NotificationCenter()
        let events = InterruptionEventRecorder()
        var otherAudio = InterruptionBackgroundHold.OtherAudio(isPlaying: true, secondaryShouldBeSilenced: true)
        let probe = InterruptionHoldProbe(watch: .init(
            probe: { otherAudio },
            activate: { nil },
            pollInterval: 0.02,
            settle: 0.05,
            window: 5,
            releaseDelay: 0
        ))
        let client = AVPlayerStreamPlaybackClient(
            audioSessionNotificationCenter: notificationCenter,
            interruptionHandler: { events.append($0) },
            interruptionHold: probe.hold
        )
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "watched-interruption", targetType: .transcriptBackedMedia,
            targetId: "watched-interruption-audio", title: "Watched interruption",
            playbackURL: audioURL.absoluteString, durationMs: 4_000
        ))
        try client.play(targetId: "watched-interruption-audio", fromMediaTimeMs: 0)

        post(.began, to: notificationCenter)
        await settle { probe.begins == 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(events.values, [.began], "the announcement is still playing")

        otherAudio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
        await settle { events.values.count == 2 }
        XCTAssertEqual(events.values, [.began, .endedShouldResume])
        XCTAssertEqual(probe.hold.outcome, .otherAudioStopped)
        post(.ended, options: .shouldResume, to: notificationCenter)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(events.values, [.began, .endedShouldResume], "a late end doesn't resume a second time")

        try client.play(targetId: "watched-interruption-audio", fromMediaTimeMs: 0)
        otherAudio = .init(isPlaying: true, secondaryShouldBeSilenced: true)
        post(.began, to: notificationCenter)
        await settle { probe.begins == 2 }
        try client.pause()
        otherAudio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(events.values, [.began, .endedShouldResume, .began], "the listener's pause keeps it paused")
        XCTAssertEqual(probe.hold.outcome, .listenerActed)
        try client.stop()
    }

    /// The observers deliver on the main queue, after the post returns.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func post(
        _ type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions = [],
        to center: NotificationCenter
    ) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if type == .ended { info[AVAudioSessionInterruptionOptionKey] = options.rawValue }
        center.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: info)
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
        let player = try XCTUnwrap(model.marginVoicePlayer.currentPlayer)
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

    /// #941: a voice that becomes unreadable after import accepts the request to play and then reports a failed
    /// item with a clock stuck at zero. The card used to keep saying "Playing" with a Pause button, and the
    /// polling loop never ended. Now the failure shows, polling stops, the Margin stays new, and Retry makes a
    /// fresh attempt. The model is read through the real AVPlayer, not through a requested flag.
    func testASharedMarginWhoseVoiceFailsShowsFailureAndRetriesFresh() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "item-pill", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        try Data("not audio".utf8).write(to: URL(fileURLWithPath: fixture.record.audioPath!))
        let model = fixture.model
        model.refreshMarginRows()
        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        XCTAssertNotNil(model.playingImportedCommentary)
        XCTAssertNotEqual(model.importedCommentaryPhase, .playing, "asking to play is not playing")
        let firstPlayer = try XCTUnwrap(model.marginVoicePlayer.currentPlayer)
        let pollTask = try XCTUnwrap(model.marginVoicePlayer.completionTask)

        try waitUntil("the failure shows") { model.importedCommentaryPhase.isFailed }
        XCTAssertEqual(model.importedCommentaryPhase, .failed(.unreadable))
        XCTAssertFalse(model.activePlaybackIsPlaying, "the transport offers Play (Retry), not Pause")
        XCTAssertNotNil(model.playingImportedCommentary, "the card stays so Retry and Return to Source are offered")
        XCTAssertNil(firstPlayer.currentItem, "the failed player is released")
        XCTAssertNil(try fixture.storedRecord()?.firstHeardAt, "a voice that never played stays new")
        XCTAssertNotEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1, "Now Playing does not claim playback")
        XCTAssertNil(model.marginVoicePlayer.completionTask, "the polling task is gone")
        XCTAssertTrue(pollTask.isCancelled, "the polling task was cancelled, not just forgotten")

        // Retry starts a fresh attempt on a new player; it fails afresh because the file is still unreadable.
        model.retryImportedCommentary()
        XCTAssertEqual(model.importedCommentaryPhase, .loading, "a retry starts over rather than inheriting the failure")
        let secondPlayer = try XCTUnwrap(model.marginVoicePlayer.currentPlayer)
        XCTAssertFalse(secondPlayer === firstPlayer)
        try waitUntil("the retry fails too") { model.importedCommentaryPhase.isFailed }

        // Return to Source leaves cleanly, and the Margin is still new.
        model.returnToSourceFromImportedCommentary()
        XCTAssertNil(model.playingImportedCommentary)
        XCTAssertEqual(model.importedCommentaryPhase, .loading)
        model.refreshMarginRows()
        XCTAssertEqual(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id }?.isNew, true)
    }

    /// #941: a readable voice shows Playing only once its clock advances, and Paused when the listener pauses.
    func testASharedMarginWithAReadableVoiceMovesFromLoadingToPlayingToPaused() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "item-pill", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        XCTAssertEqual(model.importedCommentaryPhase, .loading)
        try waitUntil("its clock advances") { model.importedCommentaryPhase == .playing }
        XCTAssertTrue(model.activePlaybackIsPlaying)
        model.playPause()
        XCTAssertEqual(model.importedCommentaryPhase, .paused)
        XCTAssertFalse(model.activePlaybackIsPlaying)
        model.playPause()
        XCTAssertTrue(model.activePlaybackIsPlaying)
        model.stopInterjectionAudioPlayback()
    }

    /// #941 audit: in mixing mode nothing tells the model the system paused the player (a call, Siri,
    /// unplugged headphones). It reads Paused, not a dead voice, and resumes in place.
    func testASharedMarginThePlayerPausedOnItsOwnReadsPausedAndResumesInPlace() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "item-pill", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        let player = try XCTUnwrap(model.marginVoicePlayer.currentPlayer)
        try waitUntil("its clock advances") { model.importedCommentaryPhase == .playing }
        player.pause() // the system's pause: the model is not told
        try waitUntil("it reads Paused") { model.importedCommentaryPhase == .paused }
        XCTAssertFalse(model.activePlaybackIsPlaying, "the transport offers Play")
        XCTAssertNotNil(model.playingImportedCommentary)
        let pausedAt = player.currentTime().seconds
        model.playPause() // Play resumes the same player; it must not be treated as a pause request
        XCTAssertTrue(model.activePlaybackIsPlaying)
        XCTAssertTrue(player === model.marginVoicePlayer.currentPlayer)
        try waitUntil("it plays on from where it stopped") { player.currentTime().seconds > pausedAt + 0.05 }
        model.stopInterjectionAudioPlayback()
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
        XCTAssertNil(model.diagnostics["marginMoment.chime"], "a muted layer's Margin plays with no chime (#932)")
    }

    /// #474: "Review new Margins" plays each new shared Margin in turn, marks each heard, and then leaves the
    /// source paused where the listener left off.
    func testReviewingNewMarginsPlaysEachInOrderAndLeavesTheSourcePaused() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, secondMarginAtMs: 2_500)
        defer { fixture.cleanUp() }
        let model = fixture.model
        XCTAssertEqual(model.newSharedMargins(itemId: "real-source").map(\.interjection.id), ["note", "note2"])

        model.reviewNewMargins(itemId: "real-source", thenContinue: false)
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertEqual(model.marginMoment?.isReview, true)
        XCTAssertEqual(model.screen, .playback)
        try waitUntil("the first Margin's voice plays", timeout: 10) { try fixture.storedRecord("note")?.firstHeardAt != nil }
        XCTAssertNil(try fixture.storedRecord("note2")?.firstHeardAt, "the second waits its turn")
        try waitUntil("the second Margin's voice plays", timeout: 15) { try fixture.storedRecord("note2")?.firstHeardAt != nil }
        let first = try XCTUnwrap(try fixture.storedRecord("note")?.firstHeardAt)
        let second = try XCTUnwrap(try fixture.storedRecord("note2")?.firstHeardAt)
        XCTAssertLessThan(first, second, "heard in the order they sit in the episode")
        try waitUntil("the review ends after the last Margin", timeout: 10) { model.marginMoment == nil }
        XCTAssertEqual(model.snapshot.status, .paused, "it stops after the last one")
        XCTAssertTrue(model.newSharedMargins(itemId: "real-source").isEmpty, "both are heard now")
    }

    /// #474: Stop on the review card stops the voice and leaves the source paused; nothing else plays.
    func testStoppingAReviewLeavesTheSourcePausedAndPlaysNothingElse() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, secondMarginAtMs: 2_500)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.reviewNewMargins(itemId: "real-source", thenContinue: true)
        defer { model.endMarginMoment(); model.pause() }
        try waitUntil("the first Margin's voice plays", timeout: 10) { model.marginMoment?.isPlayingMargin == true }
        model.stopReviewingNewMargins()
        XCTAssertNil(model.marginMoment)
        XCTAssertEqual(model.snapshot.status, .paused)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertNil(try fixture.storedRecord("note2")?.firstHeardAt, "the second Margin never plays after Stop")
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertFalse(model.sharedMarginOffers.announcedIDs.contains("note2"),
                       "the Margin Stop never reached goes back to the automatic prompts")
        XCTAssertTrue(model.sharedMarginOffers.announcedIDs.contains(fixture.record.id),
                      "the one already heard isn't prompted again")
    }

    /// #474 audit: a review that ends before its last Margin (a Timeline jump, Add Margin, the session closing) must
    /// give the item back where the listener left off. Left where the review had got to, the session is saved there
    /// and the next Continue lands in the wrong place, which is the problem the review exists to fix.
    func testAReviewThatEndsEarlyGivesTheItemBackWhereTheListenerWas() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, secondMarginAtMs: 25_000)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertTrue(model.seekMedia(toMediaTimeMs: 12_000))
        model.pause()
        let leftOffAt = try XCTUnwrap(model.snapshot.currentMediaTimeMs)

        model.reviewNewMargins(itemId: "real-source", thenContinue: true)
        try waitUntil("the first Margin's voice plays", timeout: 10) { model.marginMoment?.isPlayingMargin == true }
        XCTAssertLessThan(model.snapshot.currentMediaTimeMs ?? .max, 5_000, "the review moved the source to the Margin at 1 s")

        model.endMarginMoment() // what a Timeline jump or the session closing does
        XCTAssertNil(model.marginMoment)
        XCTAssertLessThan(abs((model.snapshot.currentMediaTimeMs ?? .max) - leftOffAt), 1_000,
                          "back where the listener left off, not where the review had got to")
        XCTAssertEqual(model.snapshot.status, .paused, "and nothing plays on from the middle of the review")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertNil(try fixture.storedRecord("note2")?.firstHeardAt, "the Margin it never reached stays new")
        XCTAssertEqual(model.snapshot.status, .paused)
    }

    /// #474 audit: Continue or a session list tap during a review stops the player before anything ends the moment.
    /// The review ends first, so the session is saved at the listener's place and the item resumes there.
    func testResumingTheItemDuringAReviewResumesWhereTheListenerLeftOff() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, secondMarginAtMs: 25_000)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertTrue(model.seekMedia(toMediaTimeMs: 12_000))
        model.pause()
        let leftOffAt = try XCTUnwrap(model.snapshot.currentMediaTimeMs)

        model.reviewNewMargins(itemId: "real-source", thenContinue: true)
        try waitUntil("the first Margin's voice plays", timeout: 10) { model.marginMoment?.isPlayingMargin == true }

        model.startItem(id: "real-source") // Continue again: resumes this item's session
        XCTAssertNil(model.marginMoment, "the review is over")
        let resumedAt = try XCTUnwrap(model.snapshot.currentMediaTimeMs)
        XCTAssertTrue((leftOffAt - 1_000...leftOffAt + 3_000).contains(resumedAt),
                      "resumed at \(resumedAt) ms, not where the listener left off (\(leftOffAt) ms)")
    }

    /// #474 with #1672: Add Margin while a review's Margin plays holds that Margin's voice and records at its place; the
    /// review stays alive. Save or Cancel plays the Margin on, and when the review ends (here: Stop) the item goes back
    /// where the listener left off. The review used to end at the hand-off and need its own note of the place kept.
    func testAddMarginDuringAReviewHoldsTheMarginAndTheReviewCarriesOnAfterSave() throws {
        try addMarginDuringAReview(saving: true)
    }

    func testCancellingAddMarginDuringAReviewCarriesTheReviewOnToo() throws {
        try addMarginDuringAReview(saving: false)
    }

    private func addMarginDuringAReview(saving: Bool) throws {
        let fixture = try SharedMarginHearingFixture(
            itemID: "real-source", makeWAV: makeTestWAV, recordingClient: NoopRecordingClient(), secondMarginAtMs: 25_000
        )
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertTrue(model.seekMedia(toMediaTimeMs: 12_000))
        model.pause()
        let leftOffAt = try XCTUnwrap(model.snapshot.currentMediaTimeMs)

        model.reviewNewMargins(itemId: "real-source", thenContinue: true)
        try waitUntil("the first Margin's voice plays", timeout: 10) { model.marginMoment?.isPlayingMargin == true }

        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording, "Add Margin records straight away")
        XCTAssertEqual(model.marginMoment?.isReview, true, "the review is not over")
        XCTAssertEqual(model.marginMomentConductor?.isVoicePaused, true, "the Margin's voice is held where it is")
        XCTAssertLessThan(model.snapshot.currentMediaTimeMs ?? .max, 5_000, "recording at the friend's Margin, not at the listener's place")
        let owed = try XCTUnwrap(model.reviewPlaces.owed(itemId: "real-source"), "the review still owes the listener's place")
        XCTAssertEqual(owed.returnToMediaTimeMs, leftOffAt)

        if saving { model.finishInterjection() } else { model.cancelInterjection() }
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertEqual(model.marginMoment?.isReview, true, "the review carries on")
        XCTAssertEqual(model.marginMomentConductor?.isVoicePaused, false, "the Margin plays on")
        if saving {
            let saved = try XCTUnwrap(fixture.store.loadSessions(itemId: "real-source")
                .flatMap { try fixture.store.loadInterjections(sessionId: $0.id) }.first)
            XCTAssertEqual(try XCTUnwrap(saved.anchor.mediaTimeMs), 1_000, accuracy: 20, "anchored at the friend's Margin")
        }

        model.stopReviewingNewMargins()
        XCTAssertNil(model.marginMoment)
        try waitUntil("the listener is back where they left off", timeout: 8) {
            (leftOffAt - 1_000...leftOffAt + 4_000).contains(model.snapshot.currentMediaTimeMs ?? 0)
        }
        XCTAssertNil(model.reviewPlaces.owed(itemId: "real-source"), "given back, so no longer owed")
    }

    /// #474 with #1672: Write instead, tapped while Add Margin's microphone line is up (always on the first Add Margin
    /// after install), opens a written Margin at the friend's Margin and leaves that Margin's voice held where it
    /// stopped. The review stays alive and paused, and ending it still gives the listener's place back.
    func testWriteInsteadDuringAReviewLeavesTheReviewPausedAtTheMargin() throws {
        try writeInsteadDuringAReview(saving: true)
    }

    func testCancellingWriteInsteadDuringAReviewLeavesTheReviewPausedToo() throws {
        try writeInsteadDuringAReview(saving: false)
    }

    private func writeInsteadDuringAReview(saving: Bool) throws {
        let fixture = try SharedMarginHearingFixture(
            itemID: "real-source", makeWAV: makeTestWAV, recordingClient: NoopRecordingClient(),
            microphonePermissionStatus: { .undetermined }, secondMarginAtMs: 25_000
        )
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertTrue(model.seekMedia(toMediaTimeMs: 12_000))
        model.pause()
        let leftOffAt = try XCTUnwrap(model.snapshot.currentMediaTimeMs)

        model.reviewNewMargins(itemId: "real-source", thenContinue: true)
        try waitUntil("the first Margin's voice plays", timeout: 10) { model.marginMoment?.isPlayingMargin == true }

        model.beginInterjection()
        XCTAssertTrue(model.isRequestingRecordingPermission, "the microphone line is up, so nothing records yet")
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertEqual(model.marginMomentConductor?.isVoicePaused, true, "the Margin's voice is held while it waits")

        model.switchPendingVoiceCaptureToWrittenMargin()
        XCTAssertNotNil(model.writtenMarginDraft, "the written Margin opened")
        XCTAssertLessThan(model.snapshot.currentMediaTimeMs ?? .max, 5_000, "writing at the friend's Margin, not at the listener's place")
        XCTAssertEqual(model.marginMoment?.isReview, true, "the review is not over")

        if saving { model.saveWrittenMargin(text: "Answering in writing") } else { model.cancelWrittenMargin() }
        XCTAssertNil(model.writtenMarginDraft)
        XCTAssertEqual(model.marginMomentConductor?.isVoicePaused, true, "the Margin stays where it stopped, for Play")
        if saving {
            let saved = try XCTUnwrap(fixture.store.loadSessions(itemId: "real-source")
                .flatMap { try fixture.store.loadInterjections(sessionId: $0.id) }.first)
            XCTAssertEqual(try XCTUnwrap(saved.anchor.mediaTimeMs), 1_000, accuracy: 100, "anchored at the friend's Margin")
        }

        model.stopReviewingNewMargins()
        XCTAssertNil(model.marginMoment)
        try waitUntil("the listener is back where they left off", timeout: 8) {
            (leftOffAt - 1_000...leftOffAt + 4_000).contains(model.snapshot.currentMediaTimeMs ?? 0)
        }
        XCTAssertNil(model.reviewPlaces.owed(itemId: "real-source"), "given back, so no longer owed")
    }

    /// #474 audit: the app is ended mid-review (iOS reclaims it while the phone is locked). The saved session is wherever
    /// the review had got to, and the relaunch restores that session. It must restore the listener's place instead.
    func testRelaunchingAfterAReviewWasCutOffRestoresTheListenersPlace() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, secondMarginAtMs: 25_000)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertTrue(model.seekMedia(toMediaTimeMs: 12_000))
        model.pause()
        let leftOffAt = try XCTUnwrap(model.snapshot.currentMediaTimeMs)

        model.reviewNewMargins(itemId: "real-source", thenContinue: true)
        try waitUntil("the first Margin's voice plays", timeout: 10) { model.marginMoment?.isPlayingMargin == true }
        model.pause()
        // The app ends here. What it leaves behind is the session saved at the review's place, and the note of where the
        // listener was (nothing runs the review's own ending).
        var stored = try XCTUnwrap(fixture.store.loadSession(id: try XCTUnwrap(model.snapshot.sessionId)))
        stored.status = "in_progress"
        stored.position.mediaTimeMs = 1_000
        try fixture.store.saveSession(stored)
        XCTAssertNotNil(model.reviewPlaces.owed(itemId: "real-source"), "the note was written when the review started")

        let relaunched = Gate1AppModel(
            audioPlaybackClient: RoutedAudioPlaybackClient(speech: NoopAudioPlaybackClient(), media: AVPlayerStreamPlaybackClient()),
            databaseURLOverride: fixture.databaseURL
        )
        relaunched.reviewPlaces = ReviewReturnPlaces(defaults: fixture.reviewPlaceDefaults)
        relaunched.bootstrapLibraryIfNeeded()

        XCTAssertEqual(relaunched.snapshot.itemId, "real-source", "the session is restored")
        XCTAssertEqual(relaunched.snapshot.status, .paused)
        XCTAssertEqual(try XCTUnwrap(relaunched.snapshot.currentMediaTimeMs), leftOffAt, accuracy: 1_000,
                       "paused where the listener left off, not where the review had got to")
        XCTAssertNil(relaunched.reviewPlaces.owed(itemId: "real-source"), "given back, so no longer owed")
        try waitUntil("it is saved there too, so the next launch agrees") {
            let saved = try fixture.store.loadSession(id: stored.id)?.position.mediaTimeMs ?? .max
            return abs(saved - leftOffAt) <= 1_000
        }
    }

    /// #474: "Listen without them" is remembered, so the offer isn't made at every Continue; a Margin that arrives
    /// later brings it back, and a Margin whose recording is gone isn't counted.
    func testTurningDownTheOfferStopsItBeingRepeated() throws {
        // Its own item, so what this test turns down can't reach another test's offer.
        let fixture = try SharedMarginHearingFixture(itemID: "declined-source", makeWAV: makeTestWAV, seedsItem: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        defer { model.endMarginMoment(); model.pause() }

        var offered: String?
        model.continueListening(itemId: "declined-source") { offered = $0 }
        XCTAssertEqual(offered, "declined-source")
        XCTAssertEqual(model.newSharedMargins(itemId: "declined-source").count, 1)

        model.continueWithoutNewMargins(itemId: "declined-source")
        XCTAssertEqual(model.snapshot.itemId, "declined-source")
        model.pause()
        XCTAssertEqual(model.newSharedMargins(itemId: "declined-source").count, 1, "still new, and Review new Margins still offers it")
        offered = nil
        model.continueListening(itemId: "declined-source") { offered = $0 }
        XCTAssertNil(offered, "turned down, so Continue just continues")
    }

    /// #474 (owner's co-op test): Continue on an item with new shared Margins asks first, and starts the item at once
    /// when there is nothing new to hear.
    func testContinueOffersNewMarginsBeforeStartingTheItem() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        defer { model.endMarginMoment(); model.pause() }

        var offered: String?
        model.continueListening(itemId: "real-source") { offered = $0 }
        XCTAssertEqual(offered, "real-source", "the question comes before anything plays")
        XCTAssertNotEqual(model.snapshot.itemId, "real-source")
        XCTAssertNil(model.marginMoment)

        _ = try fixture.store.markImportedCommentaryInterjectionHeard(id: fixture.record.id, at: Date())
        offered = nil
        model.continueListening(itemId: "real-source") { offered = $0 }
        XCTAssertNil(offered, "nothing is new, so Continue just continues")
        XCTAssertEqual(model.snapshot.itemId, "real-source")
    }

    /// #474 review: a Margin voice already playing when a review starts stops, instead of playing over it, and its
    /// end no longer owes the source back, which would resume the episode mid-review.
    func testStartingAReviewStopsTheMarginVoiceAlreadyPlaying() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, secondMarginAtMs: 2_500)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.endMarginMoment(); model.stopInterjectionAudioPlayback(); model.pause() }
        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        try waitUntil("its voice plays") { model.importedCommentaryPhase == .playing }
        XCTAssertTrue(model.sharedMarginReturn.heldByVoice, "the voice paused the playing episode and owes it back")

        model.reviewNewMargins(itemId: "real-source", thenContinue: false)
        XCTAssertEqual(model.marginMoment?.isReview, true)
        XCTAssertNil(model.playingImportedCommentary, "the voice already playing gives way to the review")
        XCTAssertFalse(model.sharedMarginReturn.heldByVoice, "its end can't resume the episode mid-review")
    }

    /// #474 review: a shared-Margin card waiting when a review starts is cleared, so it can't play over the review.
    func testStartingAReviewClearsAWaitingSharedMarginCard() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, secondMarginAtMs: 2_500)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.endMarginMoment(); model.pause() }
        model.pendingImportedCommentary = ImportedCommentaryPrompt(layer: fixture.layer, interjection: fixture.record, index: 1, count: 2)
        model.sharedMarginReturn.promptShown(sourceWasPlaying: true)

        model.reviewNewMargins(itemId: "real-source", thenContinue: false)
        XCTAssertEqual(model.marginMoment?.isReview, true)
        XCTAssertNil(model.pendingImportedCommentary, "the waiting card gives way to the review")
        XCTAssertFalse(model.sharedMarginReturn.heldByPrompt, "the dismissed card no longer owes the episode back")
    }

    /// #474 review: the lead-in to a new Margin can cross one already heard. It isn't offered over the review, which
    /// would pause the episode and stall it; the review plays the new Margin.
    func testNoSharedMarginIsOfferedOverAReview() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, secondMarginAtMs: 2_500)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.markSharedMarginHeard(fixture.record)
        XCTAssertEqual(model.newSharedMargins(itemId: "real-source").map(\.interjection.id), ["note2"])

        model.reviewNewMargins(itemId: "real-source", thenContinue: false)
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertLessThan(model.snapshot.currentMediaTimeMs ?? 0, 1_000, "the review plays through the heard Margin at 1 s")
        var offered: String?
        try waitUntil("the new Margin's voice plays", timeout: 10) {
            offered = offered ?? model.pendingImportedCommentary?.interjection.id
            return try fixture.storedRecord("note2")?.firstHeardAt != nil
        }
        XCTAssertNil(offered, "nothing is offered over the review")
    }

    /// #1671: the owner's phone heard two Margins at once. A moment's voice (Play this moment, Now's rows) is the
    /// conductor's own player, apart from the one that plays a Margin from its detail, and starting through one route
    /// never stopped the other. Starting a Margin now stops any other Margin voice first.
    func testStartingAnOwnMarginStopsAMomentsVoiceThatIsPlaying() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })
        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.stopInterjectionAudioPlayback(); model.pause() }
        model.playMarginMomentNow()
        XCTAssertEqual(marginMomentVoice(model)?.isPlaying, true, "precondition: the moment's voice is playing")
        model.refreshDiagnostics() // the tap that shows Diagnostics must not wipe the log
        XCTAssertEqual(model.diagnostics["marginVoice.events"], "start:moment")

        let own = Interjection(
            id: "own-margin", itemId: "real-source", sessionId: try XCTUnwrap(model.snapshot.sessionId),
            targetType: .item, targetId: "real-source", createdAt: Date(), roughPercent: 3,
            anchor: Anchor(anchorType: .transcript, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 1_000),
            audioPath: fixture.record.audioPath, audioStatus: "recorded", transcriptionStatus: "complete",
            transcript: nil, cleanedTranscript: nil, displayText: "My Margin", status: "active"
        )
        try fixture.store.saveInterjection(own)
        model.toggleInterjectionAudioPlayback(own)

        XCTAssertTrue(model.isPlayingInterjectionAudio(own), "your Margin plays")
        XCTAssertNotEqual(marginMomentVoice(model)?.isPlaying, true, "the moment's voice stopped: one voice at a time")
        XCTAssertNil(model.marginMoment)
        let events = try XCTUnwrap(model.diagnostics["marginVoice.events"])
        XCTAssertTrue(events.hasSuffix("stop:moment | start:own"), "Diagnostics name both players: \(events)")
    }

    /// #1671: the same from the other side. A shared Margin heard from its card stops a moment's voice first.
    func testListeningToASharedMarginStopsAMomentsVoiceThatIsPlaying() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })
        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.stopInterjectionAudioPlayback(); model.pause() }
        model.playMarginMomentNow()
        XCTAssertEqual(marginMomentVoice(model)?.isPlaying, true, "precondition: the moment's voice is playing")

        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)

        XCTAssertNotNil(model.playingImportedCommentary, "the shared Margin plays from its card")
        XCTAssertNotEqual(marginMomentVoice(model)?.isPlaying, true, "the moment's voice stopped: one voice at a time")
        let events = try XCTUnwrap(model.diagnostics["marginVoice.events"])
        XCTAssertTrue(events.hasSuffix("stop:moment | start:shared"), "Diagnostics name both players: \(events)")
    }

    /// #1671 audit: a moment's voice the listener paused leaves everything paused. Starting a Margin over it stops
    /// the voice but promises no return, or the episode would start by itself when that Margin ends (#1538).
    func testAPausedMomentVoiceCutByAnOwnMarginDoesNotPromiseTheSourceBack() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })
        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.stopInterjectionAudioPlayback(); model.pause() }
        model.playMarginMomentNow()
        XCTAssertEqual(marginMomentVoice(model)?.isPlaying, true, "precondition: the moment's voice is playing")
        model.playPause()
        XCTAssertEqual(model.marginMomentConductor?.isVoicePaused, true, "precondition: the listener paused it")

        let own = Interjection(
            id: "own-margin", itemId: "real-source", sessionId: try XCTUnwrap(model.snapshot.sessionId),
            targetType: .item, targetId: "real-source", createdAt: Date(), roughPercent: 3,
            anchor: Anchor(anchorType: .transcript, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 1_000),
            audioPath: fixture.record.audioPath, audioStatus: "recorded", transcriptionStatus: "complete",
            transcript: nil, cleanedTranscript: nil, displayText: "My Margin", status: "active"
        )
        try fixture.store.saveInterjection(own)
        model.toggleInterjectionAudioPlayback(own)

        XCTAssertTrue(model.isPlayingInterjectionAudio(own), "your Margin plays")
        XCTAssertFalse(model.sharedMarginReturn.heldByVoice, "nothing was playing, so nothing comes back when it ends")
    }

    /// #1671 audit: the log names every stop, so a moment's voice that ended on its own, then a Margin of yours,
    /// reads `start:moment | stop:moment | start:own`, which is not what two voices at once would leave.
    func testAMomentVoiceThatEndsOnItsOwnLogsItsStop() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })
        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.pause() }
        model.playMarginMomentNow()
        XCTAssertEqual(marginMomentVoice(model)?.isPlaying, true, "precondition: the moment's voice is playing")

        try waitUntil("the voice ends by itself", timeout: 10) { model.snapshot.status == .playing }
        XCTAssertEqual(model.diagnostics["marginVoice.events"], "start:moment | stop:moment")
    }

    /// #1308 (ANC-08): the host test drives the real player through pause and resume closures it wrote itself. This
    /// one goes through the app's own: the episode stands still while their voice plays, then plays on by itself.
    func testTheEpisodePlaysOnAfterASharedMarginsMoment() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })

        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.pause() }
        model.playMarginMomentNow()
        XCTAssertEqual(marginMomentVoice(model)?.isPlaying, true, "their voice is playing")
        XCTAssertFalse(model.snapshot.status.isPlaybackActive, "the episode is paused while their voice plays")
        let pausedAtMs = model.snapshot.currentMediaTimeMs ?? 0

        // The voice is 2 s long. When it ends, the app's resume closure must restart the episode.
        try waitUntil("the episode plays again after their voice", timeout: 10) { model.snapshot.status == .playing }
        XCTAssertNotEqual(marginMomentVoice(model)?.isPlaying, true, "their voice has finished")
        try waitUntil("the episode's clock moves on past the Margin", timeout: 5) {
            (model.snapshot.currentMediaTimeMs ?? 0) >= pausedAtMs + 1_000
        }
    }

    /// #1036: Start New Session closed the engine's session without the hook that ends a Margin moment. A new session
    /// of the same item (item page "Start New Session", or Play on a finished session) left the moment's voice and
    /// card alive over the restarted source. It must end the moment, as the mini player's X does.
    func testStartingANewSessionOfTheSameItemEndsAPlayingMarginMoment() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })
        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.pause() }
        model.playMarginMomentNow()
        XCTAssertNotNil(model.marginMoment, "the moment is playing before the new session")
        weak var voice = try XCTUnwrap(marginMomentVoice(model), "the friend's voice is playing before the new session")
        XCTAssertEqual(voice?.isPlaying, true, "the friend's voice is playing before the new session")
        let firstSessionId = try XCTUnwrap(model.snapshot.sessionId)

        model.startNewSession(id: "real-source")

        XCTAssertNil(model.marginMoment, "the new session ended the Margin moment")
        XCTAssertFalse(model.marginMomentVoiceIsPaused)
        XCTAssertNotEqual(voice?.isPlaying, true, "the friend's voice stopped, not just its card")
        XCTAssertNotEqual(model.snapshot.sessionId, firstSessionId, "a new session of the same item started")
        XCTAssertEqual(model.snapshot.itemId, "real-source")
    }

    /// #1045 (NAR-05): the engine tests pass their own closure to `endSession(stoppingInlinePlayback:)`, so they
    /// pass whether or not the app supplies `endMarginMoment`. This closes the session the way the mini player's X
    /// and End Session do (`closeCurrentSession`) on the moment's own item, so the item check in
    /// `observeMarginMoment` can't end the moment instead. The moment and its voice must both end.
    func testClosingTheSessionEndsAPlayingMarginMomentAndStopsItsVoice() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })
        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.pause() }
        model.playMarginMomentNow()
        XCTAssertNotNil(model.marginMoment, "the moment is playing before the close")
        weak var voice = try XCTUnwrap(marginMomentVoice(model), "the friend's voice is playing before the close")
        XCTAssertEqual(voice?.isPlaying, true, "the friend's voice is playing before the close")

        model.endSession()

        XCTAssertNil(model.marginMoment, "closing the session ended the Margin moment")
        XCTAssertFalse(model.marginMomentVoiceIsPaused)
        XCTAssertNotEqual(voice?.isPlaying, true, "the friend's voice stopped")
    }

    /// The Margin moment's voice player, read through the model's conductor (both are private).
    private func marginMomentVoice(_ model: Gate1AppModel) -> AVAudioPlayer? {
        let conductor = Mirror(reflecting: model).children.first { $0.label == "marginMomentConductor" }?.value as? MarginMomentConductor
        guard let conductor else { return nil }
        return Mirror(reflecting: conductor).children.first { $0.label == "voice" }?.value as? AVAudioPlayer
    }

    /// #932 (found on the phone): tapping a friend's Margin in the Timeline started their voice with no chime.
    /// The moment now plays the chime the automatic prompt has always played, and their voice follows it.
    func testPlayingASharedMarginsMomentChimesBeforeTheirVoice() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, layerIsMuted: false)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })

        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertNil(model.diagnostics["marginMoment.chime"], "the lead-in plays the episode, not the chime")
        model.playMarginMomentNow()
        XCTAssertEqual(model.diagnostics["marginMoment.chime"], "played:shared::received::note", "the chime plays first")
        XCTAssertNil(try fixture.storedRecord()?.firstHeardAt, "their voice waits for the chime")
        try waitUntil("their voice follows the chime") { try fixture.storedRecord()?.firstHeardAt != nil }
        XCTAssertNil(model.pendingImportedCommentary, "the automatic prompt adds no second cue for the same Margin")
    }

    /// #932 (Codex audit): losing the headphones during the chime must not let their voice start through the
    /// speaker. The voice waits for Play.
    func testLosingTheHeadphonesDuringTheChimeHoldsTheVoiceUntilPlay() throws {
        try assertTheChimedVoiceWaitsForPlay(after: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        ], posting: AVAudioSession.routeChangeNotification)
    }

    /// #932 (Codex audit): a call during the chime makes the system refuse the voice that starts after it, and the
    /// refusal used to consume the Margin as unplayable. The voice waits for Play instead.
    func testACallDuringTheChimeHoldsTheVoiceUntilPlay() throws {
        try assertTheChimedVoiceWaitsForPlay(after: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ], posting: AVAudioSession.interruptionNotification)
    }

    private func assertTheChimedVoiceWaitsForPlay(
        after userInfo: [AnyHashable: Any], posting name: Notification.Name
    ) throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, layerIsMuted: false)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })
        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.pause() }
        model.playMarginMomentNow()
        XCTAssertNotNil(model.diagnostics["marginMoment.chime"], "the chime is playing")

        NotificationCenter.default.post(name: name, object: AVAudioSession.sharedInstance(), userInfo: userInfo)
        try waitUntil("the Margin is held") { model.marginMomentVoiceIsPaused }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertNil(try fixture.storedRecord()?.firstHeardAt, "their voice didn't start by itself")
        XCTAssertNotNil(model.marginMoment?.playing, "the Margin is still waiting, not consumed")

        model.playPause()
        XCTAssertNotNil(try fixture.storedRecord()?.firstHeardAt, "Play starts their voice")
    }

    /// #866 (found on the phone): Add Margin while a shared Margin's moment plays its voice used to be refused.
    /// It now records at once at the shared Margin's place (not where the source paused a tick after it). The voice
    /// is held while it records and plays on from where it stopped after the save (#1672), and then the source
    /// carries on like after any Margin (J3).
    func testAddMarginWhileAMarginMomentPlaysRecordsAtThatMargin() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, recordingClient: NoopRecordingClient())
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })
        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.pause() }
        try waitUntil("playback reaches the shared Margin and its voice plays", timeout: 10) {
            model.marginMoment?.isPlayingMargin == true
        }
        XCTAssertEqual(model.marginMoment?.playing?.mediaTimeMs, 1_000)
        try waitUntil("the voice has played a little") { (self.marginMomentVoice(model)?.currentTime ?? 0) > 0.2 }

        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording, "Add Margin records straight away, with no warning")
        XCTAssertEqual(model.marginMomentConductor?.isVoicePaused, true, "the Margin's voice is held where it is, not dropped")
        XCTAssertNotNil(model.marginMoment?.playing)
        let heldAt = try XCTUnwrap(marginMomentVoice(model)?.currentTime)
        XCTAssertNotEqual(model.statusMessage, "Skip or finish the Margin that's playing before recording a new one.")

        model.finishInterjection()
        let saved = try XCTUnwrap(fixture.store.loadSessions(itemId: "real-source")
            .flatMap { try fixture.store.loadInterjections(sessionId: $0.id) }.first)
        XCTAssertEqual(try XCTUnwrap(saved.anchor.mediaTimeMs), 1_000, accuracy: 20, "anchored at the playing Margin")
        XCTAssertEqual(model.marginMomentConductor?.isVoicePaused, false, "Save plays the Margin on")
        XCTAssertEqual(marginMomentVoice(model)?.isPlaying, true)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(marginMomentVoice(model)?.currentTime), heldAt, "from where it stopped, not from the start")
        XCTAssertEqual(model.snapshot.status, .paused, "the source waits for the Margin to end")
        try waitUntil("the Margin ends and the source carries on", timeout: 10) { model.snapshot.status == .playing }
        XCTAssertNil(model.marginMoment, "the Margin that played on is over")
    }

    /// #1672 (found on the phone): cancelling the Margin recorded over a Margin plays the first one on too.
    func testCancellingAMarginRecordedOverAMarginMomentPlaysThatMarginOn() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, recordingClient: NoopRecordingClient())
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })
        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.pause() }
        try waitUntil("playback reaches the shared Margin and its voice plays", timeout: 10) {
            model.marginMoment?.isPlayingMargin == true
        }

        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)
        XCTAssertEqual(model.marginMomentConductor?.isVoicePaused, true)
        model.cancelInterjection()

        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertEqual(model.marginMomentConductor?.isVoicePaused, false, "Cancel plays the Margin on")
        XCTAssertEqual(model.snapshot.status, .paused, "the source waits for the Margin to end")
        try waitUntil("the Margin ends and the source carries on", timeout: 10) { model.snapshot.status == .playing }
    }

    /// #1672 (found on the phone): pausing during a Margin's moment from the Lock Screen or headphones (the compact
    /// transport) paused the Margin's voice no more than it resumed the source behind it: Play sent the listener back
    /// to the item over the Margin. Play and Pause act on the voice, in place.
    func testCompactPauseAndPlayDuringAMarginMomentActOnThatMargin() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })
        model.playSharedMarginMoment(row)
        defer { model.endMarginMoment(); model.stopInterjectionAudioPlayback(); model.pause() }
        model.playMarginMomentNow()
        XCTAssertEqual(marginMomentVoice(model)?.isPlaying, true, "precondition: the Margin's voice is playing")
        XCTAssertEqual(model.snapshot.status, .paused, "precondition: the source waits behind it")

        model.dispatchGate2CompactCommand(.togglePlayPause, origin: "now_playing")
        XCTAssertEqual(model.marginMomentConductor?.isVoicePaused, true, "Pause holds the Margin")
        XCTAssertEqual(model.snapshot.status, .paused)

        model.dispatchGate2CompactCommand(.togglePlayPause, origin: "now_playing")
        XCTAssertEqual(model.marginMomentConductor?.isVoicePaused, false, "Play carries the Margin on")
        XCTAssertEqual(marginMomentVoice(model)?.isPlaying, true)
        XCTAssertEqual(model.snapshot.status, .paused, "Play did not start the source over the Margin")
    }

    /// #1672 (found on the phone): your own Margin, played from its detail, paused sent the listener back to the item:
    /// the player had no pause, so Play resumed the source over the voice. Pause holds the voice and Play plays it on.
    func testPausingYourOwnMarginHoldsItAndPlayCarriesItOnNotTheSource() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.stopInterjectionAudioPlayback(); model.pause() }
        try waitUntil("the source plays") { (model.snapshot.currentMediaTimeMs ?? 0) > 0 || model.snapshot.status == .playing }
        let own = try fixture.addOwnMargin(sessionID: try XCTUnwrap(model.snapshot.sessionId))
        model.toggleInterjectionAudioPlayback(own)
        XCTAssertTrue(model.isPlayingInterjectionAudio(own))
        XCTAssertEqual(model.snapshot.status, .paused, "hearing a Margin from its detail pauses the source")
        XCTAssertTrue(model.activePlaybackIsPlaying, "the transport shows the Margin playing")
        let player = try XCTUnwrap(model.marginVoicePlayer.currentPlayer)
        try waitUntil("the voice has played a little") { player.currentTime().seconds > 0.2 }

        model.playPause()
        XCTAssertTrue(model.isPlayingInterjectionAudio(own), "pausing is not stopping")
        XCTAssertTrue(model.ownMarginVoiceIsPaused)
        XCTAssertEqual(player.rate, 0)
        XCTAssertFalse(model.activePlaybackIsPlaying)
        XCTAssertEqual(model.snapshot.status, .paused)
        let heldAt = player.currentTime().seconds

        model.playPause()
        XCTAssertFalse(model.ownMarginVoiceIsPaused, "Play carries the Margin on")
        XCTAssertTrue(model.isPlayingInterjectionAudio(own))
        XCTAssertEqual(model.snapshot.status, .paused, "Play did not start the source over the Margin")
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, heldAt, "from where it stopped")

        model.dispatchGate2CompactCommand(.pause, origin: "now_playing")
        XCTAssertTrue(model.ownMarginVoiceIsPaused, "the Lock Screen Pause holds it too")
        model.dispatchGate2CompactCommand(.play, origin: "now_playing")
        XCTAssertFalse(model.ownMarginVoiceIsPaused)
        XCTAssertEqual(model.snapshot.status, .paused)

        try waitUntil("the Margin ends and the source carries on", timeout: 10) { model.snapshot.status == .playing }
        XCTAssertFalse(model.isPlayingInterjectionAudio(own))
    }

    /// #866: the same from the Lock Screen / Live Activity Add Margin, while a shared Margin opened from the list plays
    /// with the source paused far from it. The new Margin belongs at the shared Margin, not at 5 s.
    func testCompactAddMarginWhileASharedMarginPlaysRecordsAtThatMargin() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, recordingClient: NoopRecordingClient())
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.pause() }
        try waitUntil("the source plays") { (model.snapshot.currentMediaTimeMs ?? 0) > 0 || model.snapshot.status == .playing }
        model.seekMedia(toMediaTimeMs: 5_000)
        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        XCTAssertNotNil(model.playingImportedCommentary)
        XCTAssertEqual(model.snapshot.status, .paused)

        model.dispatchGate2CompactCommand(.beginInterjection, origin: "live_activity")
        XCTAssertTrue(model.snapshot.isRecording, "the compact Add Margin records too")
        XCTAssertNotNil(model.playingImportedCommentary, "the shared Margin is held while it records (#1672)")
        XCTAssertTrue(model.importedCommentaryIsPaused)
        XCTAssertEqual(model.diagnostics["marginCaptureHandoff"], "seekMedia(ms: 1000)")

        model.dispatchGate2CompactCommand(.finishInterjection, origin: "live_activity")
        XCTAssertFalse(model.snapshot.isRecording)
        let saved = try XCTUnwrap(fixture.store.loadSessions(itemId: "real-source")
            .flatMap { try fixture.store.loadInterjections(sessionId: $0.id) }.first)
        XCTAssertEqual(try XCTUnwrap(saved.anchor.mediaTimeMs), 1_000, accuracy: 20, "anchored at the shared Margin")
        XCTAssertNotNil(model.playingImportedCommentary, "Save plays the shared Margin on")
        XCTAssertFalse(model.importedCommentaryIsPaused)
        XCTAssertEqual(model.snapshot.status, .paused, "the source waits for the shared Margin to end")
        try waitUntil("the source carries on past the shared Margin", timeout: 12) {
            model.snapshot.status == .playing && (model.snapshot.currentMediaTimeMs ?? 0) > 1_500
                || model.pendingImportedCommentary != nil
        }
        XCTAssertNil(model.pendingImportedCommentary, "the rejoin doesn't offer the shared Margin just answered")
        XCTAssertNil(model.playingImportedCommentary, "the shared Margin is over once the source carries on")
        XCTAssertEqual(model.snapshot.status, .playing)
    }

    /// #866 audit: your own Margin heard from its detail sheet (the source paused far from it) is the Margin that plays.
    /// Add Margin records at that Margin's place, not wherever the source paused.
    func testAddMarginWhileYourOwnMarginPlaysFromItsDetailRecordsAtThatMargin() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, recordingClient: NoopRecordingClient())
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.pause() }
        try waitUntil("the source plays") { (model.snapshot.currentMediaTimeMs ?? 0) > 0 || model.snapshot.status == .playing }
        model.seekMedia(toMediaTimeMs: 5_000)
        let own = try fixture.addOwnMargin(sessionID: try XCTUnwrap(model.snapshot.sessionId))
        model.toggleInterjectionAudioPlayback(own)
        XCTAssertTrue(model.isPlayingInterjectionAudio(own))
        XCTAssertEqual(model.snapshot.status, .paused, "hearing a Margin from its detail pauses the source")
        let player = try XCTUnwrap(model.marginVoicePlayer.currentPlayer)
        try waitUntil("the voice has played a little") { player.currentTime().seconds > 0.2 }

        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording, "Add Margin records straight away")
        XCTAssertTrue(model.isPlayingInterjectionAudio(own), "your Margin is held while the new one records (#1672)")
        XCTAssertTrue(model.ownMarginVoiceIsPaused)
        XCTAssertEqual(model.diagnostics["marginCaptureHandoff"], "seekMedia(ms: 1000)")
        let heldAt = player.currentTime().seconds

        model.finishInterjection()
        let saved = try XCTUnwrap(fixture.store.loadSessions(itemId: "real-source")
            .flatMap { try fixture.store.loadInterjections(sessionId: $0.id) }.first { $0.id != own.id })
        XCTAssertEqual(try XCTUnwrap(saved.anchor.mediaTimeMs), 1_000, accuracy: 20, "anchored at the Margin that played, not at 5 s")
        XCTAssertTrue(model.isPlayingInterjectionAudio(own), "Save plays your Margin on")
        XCTAssertFalse(model.ownMarginVoiceIsPaused)
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, heldAt, "from where it stopped, not from the start")
        XCTAssertEqual(model.snapshot.status, .paused, "the source waits for your Margin to end")
        try waitUntil("your Margin ends and the source carries on", timeout: 10) { model.snapshot.status == .playing }
        XCTAssertFalse(model.isPlayingInterjectionAudio(own))
    }

    /// #1672 audit: tapping a shared Margin in the Timeline while your own Margin is loaded and paused plays the shared
    /// Margin's moment. The moment resumes the source with `resumePlayback()`, which now plays a paused own Margin on
    /// first; the own voice has to be let go before that, as for a Margin of your own (`playMarginMoment`).
    func testTappingASharedMarginLetsGoOfYourPausedOwnMarginAndPlaysTheMoment() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.endMarginMoment(); model.stopInterjectionAudioPlayback(); model.pause() }
        try waitUntil("the source plays") { (model.snapshot.currentMediaTimeMs ?? 0) > 0 || model.snapshot.status == .playing }
        let own = try fixture.addOwnMargin(sessionID: try XCTUnwrap(model.snapshot.sessionId))
        model.toggleInterjectionAudioPlayback(own)
        model.playPause()
        XCTAssertTrue(model.ownMarginVoiceIsPaused, "precondition: your Margin is loaded and paused")
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.sharedMarginRows.first { $0.interjection.id == fixture.record.id })

        model.playSharedMarginMoment(row)

        XCTAssertFalse(model.isPlayingInterjectionAudio(own), "your Margin is let go, not picked up again")
        XCTAssertFalse(model.ownMarginVoiceIsPaused)
        try waitUntil("playback reaches the shared Margin and its voice plays", timeout: 10) {
            model.marginMoment?.isPlayingMargin == true
        }
    }

    /// #1672 audit: Add a Margin over a sounding Margin, then "Write instead" while the microphone question is up,
    /// leaves no hold behind. A later Add a Margin over the same Margin, which the listener left paused, must not
    /// play it on after Save.
    func testWritingInsteadLeavesNoHoldThatPlaysAPausedMarginAfterALaterSave() throws {
        // The first tap waits on the microphone primer, so the question stays up with no async answer to time; the
        // second finds the microphone granted. (This runs as a plain test: the waits below spin the main run loop,
        // which an async test body would hold the main actor against.)
        let microphone = MicrophoneStatusBox()
        let fixture = try SharedMarginHearingFixture(
            itemID: "real-source", makeWAV: makeTestWAV, recordingClient: NoopRecordingClient(),
            microphonePermissionStatus: { microphone.status }
        )
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.stopInterjectionAudioPlayback(); model.pause() }
        try waitUntil("the source plays") { (model.snapshot.currentMediaTimeMs ?? 0) > 0 || model.snapshot.status == .playing }
        let own = try fixture.addOwnMargin(sessionID: try XCTUnwrap(model.snapshot.sessionId))
        model.toggleInterjectionAudioPlayback(own)
        let player = try XCTUnwrap(model.marginVoicePlayer.currentPlayer)
        try waitUntil("the voice has played a little") { player.currentTime().seconds > 0.2 }

        microphone.status = .undetermined
        model.beginInterjection()
        XCTAssertTrue(model.isRequestingRecordingPermission, "the microphone question is up")
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertTrue(model.ownMarginVoiceIsPaused, "your sounding Margin is held while it waits")
        model.switchPendingVoiceCaptureToWrittenMargin()
        model.cancelWrittenMargin()
        XCTAssertNil(model.writtenMarginDraft)
        XCTAssertTrue(model.ownMarginVoiceIsPaused, "it stays where it stopped")

        microphone.status = .granted
        model.beginInterjection()
        try waitUntil("the second Margin records") { model.snapshot.isRecording }
        XCTAssertTrue(model.ownMarginVoiceIsPaused, "still paused while the second Margin records")
        model.finishInterjection()

        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertTrue(model.ownMarginVoiceIsPaused, "a Margin the listener left paused stays paused after Save")
    }

    /// #1672 audit: the listener resumed the source over their own Margin (Lock Screen, headphones, #1538), so the source
    /// is what is playing. Add a Margin lets that Margin go, as before the hold existed, and Save puts the source back;
    /// holding the Margin would leave the source paused for good, because the Margin no longer owes it back.
    func testAddMarginWhileTheSourcePlaysOverYourMarginPutsTheSourceBackAfterSave() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, recordingClient: NoopRecordingClient())
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.stopInterjectionAudioPlayback(); model.pause() }
        try waitUntil("the source plays") { (model.snapshot.currentMediaTimeMs ?? 0) > 0 || model.snapshot.status == .playing }
        let own = try fixture.addOwnMargin(sessionID: try XCTUnwrap(model.snapshot.sessionId))
        model.toggleInterjectionAudioPlayback(own)
        model.resumePlayback()
        XCTAssertTrue(model.snapshot.status.isPlaybackActive, "precondition: the source plays over your Margin")

        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)
        XCTAssertFalse(model.isPlayingInterjectionAudio(own), "the source has the transport, so your Margin is let go")
        model.finishInterjection()

        XCTAssertFalse(model.snapshot.isRecording)
        try waitUntil("Save puts the source back") { model.snapshot.status == .playing }
    }

    /// #1672 audit: a hold marker left by an earlier recording (a Margin cut short by lost headphones keeps it) says the
    /// voice was sounding. A Margin the listener has paused since must stay paused through a later Margin's Save.
    func testALeftoverHoldMarkerDoesNotPlayAMarginTheListenerPausedAfterALaterSave() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeTestWAV, recordingClient: NoopRecordingClient())
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.stopInterjectionAudioPlayback(); model.pause() }
        try waitUntil("the source plays") { (model.snapshot.currentMediaTimeMs ?? 0) > 0 || model.snapshot.status == .playing }
        let own = try fixture.addOwnMargin(sessionID: try XCTUnwrap(model.snapshot.sessionId))
        model.toggleInterjectionAudioPlayback(own)
        let player = try XCTUnwrap(model.marginVoicePlayer.currentPlayer)
        try waitUntil("the voice has played a little") { player.currentTime().seconds > 0.2 }
        model.setOwnMarginPaused(true)
        model.marginVoiceHeldForRecording = HeldMarginVoice(kind: .own, wasSounding: true)

        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)
        model.finishInterjection()

        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertTrue(model.ownMarginVoiceIsPaused, "the listener paused it; a marker from an earlier recording doesn't play it")
    }

    // MARK: Leveled Margins (#467)

    /// The owner's report (#181): Margins played from the raw recording, so a whisper was far quieter than
    /// the episode. Each way a spoken Margin is heard must play the leveled copy once it is made.
    func testEveryWayToHearASpokenMarginPlaysItsLeveledCopy() throws {
        let fixture = try SharedMarginHearingFixture(itemID: "real-source", makeWAV: makeQuietBurstsWAV)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.startItem(id: "real-source")
        defer { model.pause() }
        try waitUntil("the source plays") { (model.snapshot.currentMediaTimeMs ?? 0) > 0 || model.snapshot.status == .playing }
        let voice = URL(fileURLWithPath: try XCTUnwrap(fixture.record.audioPath))
        let own = Interjection(
            id: "own-margin", itemId: "real-source", sessionId: try XCTUnwrap(model.snapshot.sessionId),
            targetType: .item, targetId: "real-source", createdAt: Date(), roughPercent: 3,
            anchor: Anchor(anchorType: .transcript, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 1_000),
            audioPath: voice.path, audioStatus: "recorded", transcriptionStatus: "complete",
            transcript: nil, cleanedTranscript: nil, displayText: "My Margin", status: "active"
        )
        try fixture.store.saveInterjection(own)
        let anchor = MarginMomentAnchor(marginId: "own-margin", mediaTimeMs: 1_000)
        let momentVoice = model.leveledVoiceURL(["own-margin": voice], itemId: "real-source", margins: [anchor])

        try waitUntil("the leveled copy is made", timeout: 20) { Gate1AppModel.leveledMargins.readyCopy(for: voice) != nil }
        let copy = try XCTUnwrap(Gate1AppModel.leveledMargins.readyCopy(for: voice))
        defer { try? FileManager.default.removeItem(at: copy) }
        let recorded = try XCTUnwrap(MarginLoudnessLeveler.measure(fileAt: voice).integratedLUFS)
        let leveled = try XCTUnwrap(MarginLoudnessLeveler.measure(fileAt: copy).integratedLUFS)
        XCTAssertGreaterThan(leveled, recorded + 10, "the quiet recording was turned up")

        XCTAssertEqual(momentVoice("own-margin")?.lastPathComponent, copy.lastPathComponent, "Play this moment and shared moments")

        model.toggleInterjectionAudioPlayback(own)
        XCTAssertEqual(model.diagnostics["marginLeveling"], "leveled")
        XCTAssertEqual(try playingInterjectionFileName(model), copy.lastPathComponent, "your Margin from its detail")
        model.stopInterjectionAudioPlayback()

        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        XCTAssertEqual(try playingInterjectionFileName(model), copy.lastPathComponent, "a shared Margin")
    }

    private func playingInterjectionFileName(_ model: Gate1AppModel) throws -> String {
        let player = try XCTUnwrap(model.marginVoicePlayer.currentPlayer)
        return try XCTUnwrap((player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent)
    }

    /// 100 ms bursts of a quiet 440 Hz tone with silence between, like speech: loudness a recording can
    /// be turned up from (a steady tone's noise floor is its own level, which the leveler won't boost).
    private func makeQuietBurstsWAV(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "media-interruption-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frameCount = AVAudioFrameCount(44_100 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            samples[frame] = (frame / 4_410) % 2 == 0 ? sin(Float(frame) * 2 * .pi * 440 / 44_100) * 0.01 : 0
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
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

/// The microphone permission a test changes between taps.
private final class MicrophoneStatusBox {
    var status: PermissionPromptStatus = .granted
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
    /// A second Margin from the same friend ("note2"), when `secondMarginAtMs` is given (#474).
    let secondRecord: ImportedCommentaryInterjection?
    /// Where this fixture's model keeps the place a review owes the listener (#474), so a test never touches the app's own.
    let reviewPlaceDefaults: UserDefaults
    private let reviewPlaceSuite: String
    private let root: URL
    private let files: [URL]

    var databaseURL: URL { root.appending(path: "library.sqlite") }

    init(
        itemID: String,
        makeWAV: (TimeInterval) throws -> URL,
        recordingClient: RecordingClient? = nil,
        microphonePermissionStatus: (() -> PermissionPromptStatus)? = nil,
        layerIsMuted: Bool = true,
        secondMarginAtMs: Int? = nil,
        seedsItem: Bool? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "margin-heard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = try makeWAV(30)
        let voiceURL = try makeWAV(2)
        let secondVoiceURL = try secondMarginAtMs.map { _ in try makeWAV(2) }
        files = [sourceURL, voiceURL] + [secondVoiceURL].compactMap { $0 }
        let db = root.appending(path: "library.sqlite")
        let routed = RoutedAudioPlaybackClient(speech: NoopAudioPlaybackClient(), media: AVPlayerStreamPlaybackClient())
        model = Gate1AppModel(
            audioPlaybackClient: routed, recordingClient: recordingClient,
            microphonePermissionStatus: microphonePermissionStatus, databaseURLOverride: db
        )
        let placeSuite = "review-places-\(UUID().uuidString)"
        reviewPlaceSuite = placeSuite
        reviewPlaceDefaults = UserDefaults(suiteName: placeSuite)!
        model.reviewPlaces = ReviewReturnPlaces(defaults: reviewPlaceDefaults)
        model.resetAndSeed()
        store = try SQLiteSessionStore(path: db.path)
        if seedsItem ?? (itemID == "real-source") {
            try store.seed(item: Item(id: itemID, title: "Real source", mediaType: "audiobook", text: nil,
                externalReference: sourceURL.absoluteString, status: "ready", externalReferenceType: "audiobook",
                media: ItemMedia(sourceType: .nativeMediaFile, url: sourceURL.absoluteString, durationMs: 30_000, nativeMediaId: "source-audio")))
        }
        layer = ImportedCommentaryLayer(id: "received", itemId: itemID, packageDigest: "digest-\(UUID().uuidString)", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Source"),
            displayLabel: "Reviewer", importedAt: Date(), sourceResolutionStatus: .resolved,
            isEnabled: true, isMuted: layerIsMuted, revealMode: .companion)
        record = ImportedCommentaryInterjection(id: "note", layerId: layer.id, packageScopedId: "note", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media),
            approvedTranscript: "Reviewed words", audioPath: voiceURL.path, audioDurationMs: 2_000,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 1_000, confidence: 1))
        secondRecord = secondMarginAtMs.map { atMs in
            ImportedCommentaryInterjection(id: "note2", layerId: "received", packageScopedId: "note2", createdAt: Date(),
                anchorEvidence: PortableAnchorEvidence(anchorType: .media),
                approvedTranscript: "More reviewed words", audioPath: secondVoiceURL?.path, audioDurationMs: 2_000,
                resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: atMs, confidence: 1))
        }
        let records = [record] + [secondRecord].compactMap { $0 }
        _ = try store.importCommentaryLayer(layer, interjections: records)
        model.selectedItem.importedCommentaryLayers = [layer]
        model.selectedItem.importedCommentaryInterjections = [layer.id: records]
    }

    /// One of your own spoken Margins on the item, at 1 s, with the shared Margin's two-second voice.
    func addOwnMargin(sessionID: String) throws -> Interjection {
        let own = Interjection(
            id: "own-margin", itemId: "real-source", sessionId: sessionID,
            targetType: .item, targetId: "real-source", createdAt: Date(), roughPercent: 3,
            anchor: Anchor(anchorType: .transcript, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 1_000),
            audioPath: record.audioPath, audioStatus: "recorded", transcriptionStatus: "complete",
            transcript: nil, cleanedTranscript: nil, displayText: "My Margin", status: "active"
        )
        try store.saveInterjection(own)
        return own
    }

    func storedRecord(_ id: String? = nil) throws -> ImportedCommentaryInterjection? {
        try store.loadImportedCommentaryInterjections(layerId: layer.id).first { $0.id == (id ?? record.id) }
    }

    func cleanUp() {
        model.stopInterjectionAudioPlayback()
        reviewPlaceDefaults.removePersistentDomain(forName: reviewPlaceSuite)
        for url in files + [root] { try? FileManager.default.removeItem(at: url) }
    }
}

/// Stands in for UIApplication's background tasks around an `InterruptionBackgroundHold`.
@MainActor
final class InterruptionHoldProbe {
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var hold: InterruptionBackgroundHold!

    init(watch: InterruptionBackgroundHold.OtherAudioWatch? = nil) {
        hold = InterruptionBackgroundHold(
            begin: { [unowned self] _, _ in
                self.begins += 1
                var ended = false
                return { [unowned self] in
                    guard !ended else { return }
                    ended = true
                    self.ends += 1
                }
            },
            record: { _, _ in },
            otherAudioWatch: watch
        )
    }
}
