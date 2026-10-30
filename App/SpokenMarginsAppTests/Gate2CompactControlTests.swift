import ActivityKit
import AVFoundation
import MediaPlayer
import UIKit
import XCTest
@testable import SessionKit
import SessionKitAudio
@testable import SpokenMarginsApp

@MainActor
final class Gate2CompactControlTests: XCTestCase {
    func testAIResponsePlaybackStateStaysSynchronizedAcrossAppAndCompactControls() throws {
        let defaults = UserDefaults.standard
        let priorTermsVersion = defaults.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = defaults.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pastedAssistantResponse = "A playable assistant response."

        model.importPastedAssistantResponse()

        XCTAssertEqual(model.snapshot.targetType, TargetType.assistantTurnTTS.rawValue)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.gate2CompactSnapshot?.status, .playing)
        XCTAssertTrue(model.gate2CompactSnapshot?.availableCommands.contains(.pause) == true)

        model.dispatchGate2CompactCommand(.pause, origin: "live_activity_test")

        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.gate2CompactSnapshot?.status, .paused)
        XCTAssertTrue(model.gate2CompactSnapshot?.availableCommands.contains(.play) == true)

        model.dispatchGate2CompactCommand(.play, origin: "app_ui_test")

        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.gate2CompactSnapshot?.status, .playing)
        XCTAssertTrue(model.gate2CompactSnapshot?.availableCommands.contains(.pause) == true)
    }

    func testApplicationTerminationExplicitlyEndsLiveActivities() {
        let liveActivity = RecordingLiveActivityController()
        let controller = Gate2CompactControlController(liveActivity: liveActivity)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            gate2CompactControls: controller
        )

        model.handleApplicationWillTerminate()

        XCTAssertEqual(liveActivity.endAllCallCount, 1)
        XCTAssertEqual(controller.diagnostics()["gate2NowPlaying"], "ended")
    }

    func testClosingSessionExplicitlyEndsLiveActivityAndNowPlaying() {
        let liveActivity = RecordingLiveActivityController()
        let controller = Gate2CompactControlController(liveActivity: liveActivity)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            gate2CompactControls: controller
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        model.endSession()

        XCTAssertEqual(liveActivity.endAllCallCount, 1)
        XCTAssertEqual(controller.diagnostics()["gate2NowPlaying"], "ended")
        XCTAssertNil(model.snapshot.sessionId)
    }

    func testCompactSnapshotIsPublishedForSeededSession() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        XCTAssertEqual(model.gate2CompactSnapshot?.surfaceProfileId, "lock-screen-widget")
        XCTAssertEqual(model.gate2CompactSnapshot?.title, "You Can't Inspect the Pill")
        XCTAssertEqual(model.gate2CompactSnapshot?.chapterTitle, "Reasonable distrust")
        XCTAssertEqual(model.gate2CompactSnapshot?.compactSurfaceReady, true)
        XCTAssertTrue(model.gate2CompactSnapshot?.exposedCommands.contains(.play) == true)
        XCTAssertTrue(model.gate2CompactSnapshot?.exposedCommands.contains(.pause) == true)
        XCTAssertTrue(model.gate2CompactSnapshot?.exposedCommands.contains(.togglePlayPause) == true)
        XCTAssertTrue(model.gate2CompactSnapshot?.exposedCommands.contains(.seekToMediaTime) == true)
        XCTAssertTrue(model.gate2CompactSnapshot?.exposedCommands.contains(.setPlaybackRate) == true)
        XCTAssertFalse(model.gate2CompactSnapshot?.availableCommands.contains(.seekToMediaTime) == true)
        XCTAssertTrue(model.gate2CompactSnapshot?.availableCommands.contains(.setPlaybackRate) == true)
        XCTAssertTrue(model.gate2CompactSnapshot?.exposedCommands.contains(.beginInterjection) == true)
    }

    func testCompactControllerPublishesPendingSharedMarginToLiveActivity() {
        let liveActivity = RecordingLiveActivityController()
        let controller = Gate2CompactControlController(liveActivity: liveActivity)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            gate2CompactControls: controller
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let prompt = Gate2SharedMarginActivityPrompt(senderLabel: "Cole")

        let upcoming = Gate2LiveActivityNavigationEntry(
            kind: .sharedMargin,
            title: "Shared Margin",
            targetID: "margin-next",
            positionPercent: 42
        )
        controller.update(
            snapshot: model.snapshot,
            sharedMarginPrompt: prompt,
            upcomingSharedMargins: [upcoming]
        )

        XCTAssertEqual(liveActivity.lastSharedMarginPrompt, prompt)
        XCTAssertEqual(liveActivity.lastUpcomingSharedMargins, [upcoming])
    }

    func testCompactTransportCommandsDelegateAndUpdateDiagnostics() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        model.dispatchGate2CompactCommand(.togglePlayPause)

        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.diagnostics["gate2LastCommand"], "togglePlayPause")
        XCTAssertEqual(model.diagnostics["gate2LastResult"], "delegated")

        model.dispatchGate2CompactCommand(.play)

        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.diagnostics["gate2LastCommand"], "play")

        model.dispatchGate2CompactCommand(.pause)

        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.diagnostics["gate2LastCommand"], "pause")

        model.dispatchGate2CompactCommand(.play)

        model.dispatchGate2CompactCommand(.skipForward)

        XCTAssertEqual(model.diagnostics["gate2LastCommand"], "skipForward")
        XCTAssertEqual(model.gate2CompactSnapshot?.compactSurfaceReady, true)
    }

    func testNowPlayingAvailabilityUsesCompactAvailableCommandsForSeekAndRate() {
        let textSnapshot = compactSnapshot(
            targetType: TargetType.itemTextTTS.rawValue,
            availableCommands: [.togglePlayPause, .skipBack, .skipForward, .setPlaybackRate],
            durationMs: 120_000
        )
        let textAvailability = Gate2NowPlayingCommandAvailability(snapshot: textSnapshot)

        XCTAssertTrue(textAvailability.canPause)
        XCTAssertFalse(textAvailability.canSeek)
        XCTAssertTrue(textAvailability.canSetPlaybackRate)
        XCTAssertFalse(textAvailability.canPreviousTrack)
        XCTAssertFalse(textAvailability.canNextTrack)

        let mediaSnapshot = compactSnapshot(
            targetType: TargetType.transcriptBackedMedia.rawValue,
            availableCommands: [.togglePlayPause, .seekToMediaTime, .setPlaybackRate],
            durationMs: 120_000
        )
        let mediaAvailability = Gate2NowPlayingCommandAvailability(snapshot: mediaSnapshot)

        XCTAssertTrue(mediaAvailability.canSeek)
        XCTAssertTrue(mediaAvailability.canSetPlaybackRate)
        XCTAssertFalse(mediaAvailability.canPreviousTrack)
        XCTAssertFalse(mediaAvailability.canNextTrack)
    }

    func testLiveTextNowPlayingTimelineDoesNotInventDurationOrElapsedTime() {
        let textSnapshot = compactSnapshot(
            targetType: TargetType.itemTextTTS.rawValue,
            availableCommands: [.togglePlayPause, .skipBack, .skipForward],
            durationMs: 120_000
        )

        let timeline = Gate2NowPlayingTimelineMetadata(snapshot: textSnapshot)

        XCTAssertNil(timeline.elapsedSeconds)
        XCTAssertNil(timeline.durationSeconds)
        XCTAssertFalse(timeline.isLiveStream)
    }

    func testNativeMediaNowPlayingTimelineUsesCanonicalMediaTime() {
        var mediaSnapshot = compactSnapshot(
            targetType: TargetType.transcriptBackedMedia.rawValue,
            availableCommands: [.togglePlayPause, .seekToMediaTime],
            durationMs: 120_000
        )
        mediaSnapshot.currentMediaTimeMs = 30_000

        let timeline = Gate2NowPlayingTimelineMetadata(snapshot: mediaSnapshot)

        XCTAssertEqual(timeline.elapsedSeconds, 30)
        XCTAssertEqual(timeline.durationSeconds, 120)
        XCTAssertFalse(timeline.isLiveStream)
    }

    func testNowPlayingKeepsNativePlayAndPauseRegisteredWhileTextIsPaused() {
        var pausedText = compactSnapshot(
            targetType: TargetType.itemTextTTS.rawValue,
            availableCommands: [.play, .togglePlayPause, .skipBack, .skipForward],
            durationMs: nil
        )
        pausedText.status = .paused

        let availability = Gate2NowPlayingCommandAvailability(snapshot: pausedText)

        XCTAssertTrue(availability.canPlay)
        XCTAssertTrue(availability.canPause)
        XCTAssertTrue(availability.canTogglePlayPause)
        XCTAssertTrue(availability.canSkipBack)
        XCTAssertTrue(availability.canSkipForward)
    }

    /// #1030: with a Margin recording every transport command was disabled, so iOS never delivered the AirPods
    /// click (no `transport.request` in the owner's diagnostics). They stay enabled while a Margin records.
    func testNowPlayingKeepsTransportEnabledWhileAMarginRecords() {
        var recording = compactSnapshot(
            targetType: TargetType.itemTextTTS.rawValue,
            availableCommands: [.finishInterjection, .cancelInterjection],
            durationMs: nil
        )
        recording.isRecording = true
        recording.status = .recording
        recording.phase = .recordingInterjection

        let availability = Gate2NowPlayingCommandAvailability(snapshot: recording)

        XCTAssertTrue(availability.canPlay)
        XCTAssertTrue(availability.canPause)
        XCTAssertTrue(availability.canTogglePlayPause)
        XCTAssertTrue(availability.canSkipForward)
        XCTAssertTrue(availability.canStop)
        XCTAssertFalse(availability.canSkipBack, "back isn't an end command")
        XCTAssertFalse(availability.canSeek)
        XCTAssertFalse(availability.canNextTrack)
        XCTAssertFalse(availability.canPreviousTrack)
    }

    /// #2031: a headphone double-press is the next-track command, so it is enabled only while it adds a Margin.
    func testNextTrackIsEnabledOnlyWhenDoublePressAddsAMargin() {
        let playing = compactSnapshot(
            targetType: TargetType.itemTextTTS.rawValue,
            availableCommands: [.pause, .skipForward],
            durationMs: nil
        )
        XCTAssertFalse(Gate2NowPlayingCommandAvailability(snapshot: playing).canNextTrack)
        XCTAssertTrue(Gate2NowPlayingCommandAvailability(snapshot: playing, headphoneDoublePressAddsMargin: true).canNextTrack)
        var noSkip = playing
        noSkip.availableCommands = [.pause]
        XCTAssertFalse(Gate2NowPlayingCommandAvailability(snapshot: noSkip, headphoneDoublePressAddsMargin: true).canNextTrack)
    }

    func testNowPlayingTransportStaysOffWhileRecordingIfTheSurfaceCannotFinish() {
        var recording = compactSnapshot(
            targetType: TargetType.itemTextTTS.rawValue,
            availableCommands: [],
            durationMs: nil
        )
        recording.isRecording = true

        let availability = Gate2NowPlayingCommandAvailability(snapshot: recording)

        XCTAssertFalse(availability.canTogglePlayPause)
        XCTAssertFalse(availability.canSkipForward)
    }

    /// A model that has just started recording a Margin, with a capture clock the test moves (#1708).
    private func modelRecordingAMargin(clock: @escaping () -> Int) -> Gate1AppModel {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient()
        )
        model.captureWatcher = MarginCaptureWatcher(autoPoll: false, nowMs: clock)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.dispatchGate2CompactCommand(.beginInterjection)
        return model
    }

    /// The test that let #1708 ship: it sent the click the instant recording began, which is when Bluetooth
    /// headphones send a `play` nobody pressed. A click counts once the first moment has passed.
    func testHeadphoneTransportCommandEndsARecordingMarginAndKeepsIt() {
        for command in [CompactControlCommand.togglePlayPause, .play, .pause, .skipForward] {
            var nowMs = 10_000
            let model = modelRecordingAMargin { nowMs }
            XCTAssertTrue(model.snapshot.isRecording, "\(command.rawValue): the Margin records")
            nowMs += RecordingTransportGuard.startGraceMs

            model.dispatchGate2CompactCommand(command, origin: "now_playing_live_speech")

            XCTAssertFalse(model.snapshot.isRecording, "\(command.rawValue) as a Now Playing command ends the Margin")
            XCTAssertEqual(model.diagnostics["gate2LastCommand"], "finishInterjection", command.rawValue)
        }
    }

    /// #1708: the phantom `play` came 50 ms and 440 ms after recording began, from the system Now Playing path.
    func testTransportCommandInTheFirstMomentOfARecordingDoesNotEndTheMargin() {
        for command in [CompactControlCommand.togglePlayPause, .play, .pause, .skipForward] {
            for origin in ["now_playing", "now_playing_live_speech"] {
                var nowMs = 10_000
                let model = modelRecordingAMargin { nowMs }
                nowMs += 50

                model.dispatchGate2CompactCommand(command, origin: origin)
                nowMs += 390 // 440 ms in
                model.dispatchGate2CompactCommand(command, origin: origin)

                XCTAssertTrue(model.snapshot.isRecording, "\(command.rawValue) from \(origin) must not end a Margin that just began")
                XCTAssertNotEqual(model.diagnostics["gate2LastCommand"], "finishInterjection", "\(command.rawValue) from \(origin)")
            }
        }
    }

    func testTransportCommandJustAfterTheRouteChangesDoesNotEndTheMargin() {
        var nowMs = 10_000
        let model = modelRecordingAMargin { nowMs }
        nowMs += 5_000
        model.captureWatcher.routeChanged() // the headset switches profile mid-recording
        nowMs += RecordingTransportGuard.routeChangeGraceMs - 1

        model.dispatchGate2CompactCommand(.play, origin: "now_playing")

        XCTAssertTrue(model.snapshot.isRecording, "a play right after a route change is the headset, not the listener")

        nowMs += 1
        model.dispatchGate2CompactCommand(.play, origin: "now_playing")

        XCTAssertFalse(model.snapshot.isRecording, "once the route has settled a click ends the Margin again")
    }

    func testTheCaptureWatcherForgetsAnEarlierRecordingsRouteChange() {
        var nowMs = 1_000
        let watcher = MarginCaptureWatcher(autoPoll: false, nowMs: { nowMs })
        watcher.start(reading: { nil }, restart: {}, changed: { _, _ in })
        XCTAssertNil(watcher.msSinceRouteChange)
        nowMs += 400
        watcher.routeChanged()
        nowMs += 100
        XCTAssertEqual(watcher.msSinceRouteChange, 100)

        watcher.stop()
        XCTAssertNil(watcher.msSinceRouteChange)
        watcher.start(reading: { nil }, restart: {}, changed: { _, _ in })

        XCTAssertNil(watcher.msSinceRouteChange, "a route change from the last recording must not hold back this one's click")
        watcher.stop()
    }

    func testTheCaptureWatcherNotesTheSystemsRouteChangeWhileWatching() async throws {
        let center = NotificationCenter()
        var nowMs = 1_000
        let watcher = MarginCaptureWatcher(autoPoll: false, notificationCenter: center, nowMs: { nowMs })
        center.post(name: AVAudioSession.routeChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(watcher.msSinceRouteChange, "nothing records")

        watcher.start(reading: { nil }, restart: {}, changed: { _, _ in })
        nowMs += 300
        center.post(name: AVAudioSession.routeChangeNotification, object: nil)
        for _ in 0..<50 where watcher.msSinceRouteChange == nil { try await Task.sleep(for: .milliseconds(20)) }
        nowMs += 50

        XCTAssertEqual(watcher.msSinceRouteChange, 50)
        watcher.stop()
    }

    func testQueuedWidgetPlayPauseDoesNotEndARecordingMargin() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient()
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.dispatchGate2CompactCommand(.beginInterjection)

        model.dispatchGate2CompactCommand(.togglePlayPause, origin: "widget_queue")

        XCTAssertTrue(model.snapshot.isRecording, "only a Now Playing transport command ends it")
    }

    func testSkipBackWhileRecordingStillDoesNotEndTheMargin() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient()
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.dispatchGate2CompactCommand(.beginInterjection)

        model.dispatchGate2CompactCommand(.skipBack, origin: "now_playing_live_speech")

        XCTAssertTrue(model.snapshot.isRecording)
        XCTAssertEqual(model.diagnostics["recordingNavigationGuard"], "blocked_compact_skipBack")
    }

    func testQueuedNextChapterPreservesItsBoundedIntentArgument() throws {
        let suiteName = "Gate2CompactControlTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(
            Gate2CompactCommandQueue.enqueue(
                command: CompactControlCommand.jumpToChapter.rawValue,
                chapterId: "chapter-analysis",
                id: "queued-next",
                now: Date(timeIntervalSince1970: 42),
                defaults: defaults
            )
        )

        XCTAssertEqual(
            Gate2CompactCommandQueue.drain(defaults: defaults),
            [
                Gate2QueuedCompactCommand(
                    id: "queued-next",
                    command: CompactControlCommand.jumpToChapter.rawValue,
                    chapterId: "chapter-analysis",
                    createdAt: 42
                )
            ]
        )
    }

    func testQueuedSharedMarginNavigationPreservesItsTarget() throws {
        let suiteName = "Gate2CompactControlTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(
            Gate2CompactCommandQueue.enqueue(
                command: Gate2CompactApplicationCommand.jumpToSharedMargin,
                chapterId: "received-margin-7",
                id: "queued-margin",
                now: Date(timeIntervalSince1970: 84),
                defaults: defaults
            )
        )

        XCTAssertEqual(
            Gate2CompactCommandQueue.drain(defaults: defaults).first,
            Gate2QueuedCompactCommand(
                id: "queued-margin",
                command: Gate2CompactApplicationCommand.jumpToSharedMargin,
                chapterId: "received-margin-7",
                createdAt: 84
            )
        )
    }

    func testQueuedCommandDecodesPayloadWrittenBeforeChapterArguments() throws {
        let data = Data("""
        [{"id":"legacy","command":"togglePlayPause","createdAt":42}]
        """.utf8)

        let command = try XCTUnwrap(JSONDecoder().decode([Gate2QueuedCompactCommand].self, from: data).first)

        XCTAssertEqual(command.command, "togglePlayPause")
        XCTAssertNil(command.chapterId)
    }

    func testLiveActivityContentStateDecodesLegacyPayloadWithoutAvailableCommands() throws {
        let data = Data("""
        {
          "title": "Pill",
          "chapterTitle": "Opening",
          "status": "playing",
          "phase": "itemPlayback",
          "progressPercent": 42,
          "isRecording": false
        }
        """.utf8)

        let state = try JSONDecoder().decode(Gate2LiveActivityAttributes.ContentState.self, from: data)

        XCTAssertEqual(state.title, "Pill")
        XCTAssertEqual(state.availableCommands, [])
        XCTAssertNil(state.nextChapterTitle)
        XCTAssertNil(state.nextChapterId)
        XCTAssertNil(state.nextNavigationKind)
        XCTAssertNil(state.sharedMarginSenderLabel)
        // A card published by a build without Skim destinations (#115) still decodes.
        XCTAssertNil(state.skimForwardDestinationMs)
        XCTAssertNil(state.skimBackwardDestinationMs)
    }

    func testLiveActivityContentStateCarriesSkimDestinations() throws {
        let original = Gate2LiveActivityAttributes.ContentState(
            title: "Episode",
            chapterTitle: "Opening",
            status: "playing",
            phase: "itemPlayback",
            progressPercent: 42,
            isRecording: false,
            skimForwardDestinationMs: 1_122_000,
            skimBackwardDestinationMs: 725_000
        )

        let decoded = try JSONDecoder().decode(
            Gate2LiveActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.skimForwardDestinationMs, 1_122_000)
        XCTAssertEqual(decoded.skimBackwardDestinationMs, 725_000)
    }

    /// #115: the Lock Screen's Skim buttons say where they land, with the playback screen's times.
    func testSkimButtonLabelsSayWhereSkimLands() {
        XCTAssertEqual(SkimDestinationLabel.accessibilityLabel(destinationMs: 1_122_000, backward: false), "Skim forward to 18:42")
        XCTAssertEqual(SkimDestinationLabel.accessibilityLabel(destinationMs: 725_000, backward: true), "Skim back to 12:05")
        XCTAssertEqual(SkimDestinationLabel.accessibilityLabel(destinationMs: 3_909_000, backward: false), "Skim forward to 1:05:09")
        XCTAssertEqual(SkimDestinationLabel.accessibilityLabel(destinationMs: nil, backward: false), "Skim forward by scene summary")
        XCTAssertEqual(SkimDestinationLabel.accessibilityLabel(destinationMs: nil, backward: true), "Skim backward by scene summary")
        // The playback screen keeps its titles, now from the same formatter.
        XCTAssertEqual(PlaybackQualityPresentation.skimTitle(destinationMs: 1_122_000, backward: false), "Skim to 18:42")
        XCTAssertEqual(PlaybackQualityPresentation.skimTitle(destinationMs: 725_000, backward: true), "Back to 12:05")
        XCTAssertEqual(PlaybackQualityPresentation.skimTitle(destinationMs: nil, backward: false), "Skim Forward")
    }

    func testLiveActivityContentStateCarriesTheMicrophoneStateAndDefaultsToCapturing() throws {
        let stopped = Gate2LiveActivityAttributes.ContentState(
            title: "Pill",
            chapterTitle: "Opening",
            status: "recording",
            phase: "recordingInterjection",
            progressPercent: 42,
            isRecording: true,
            microphone: .stopped
        )
        let decoded = try JSONDecoder().decode(
            Gate2LiveActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(stopped)
        )
        XCTAssertEqual(decoded.microphone, .stopped)

        let legacy = try JSONDecoder().decode(Gate2LiveActivityAttributes.ContentState.self, from: Data("""
        {"title":"Pill","chapterTitle":"Opening","status":"recording","phase":"recordingInterjection","progressPercent":42,"isRecording":true}
        """.utf8))
        XCTAssertEqual(legacy.microphone, .capturing, "a payload from before this field behaves as it did")
    }

    func testLiveActivityStopsSayingRecordWhenTheMicrophoneStops() {
        let liveActivity = RecordingLiveActivityController()
        let controller = Gate2CompactControlController(liveActivity: liveActivity)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            gate2CompactControls: controller
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.snapshot.isRecording)
        XCTAssertEqual(liveActivity.lastMicrophone, .capturing, "a recorder that can report nothing counts as capturing")

        controller.setMicrophone(.stopped)

        XCTAssertEqual(liveActivity.lastMicrophone, .stopped, "the card is republished at once, not at the next playback tick")

        controller.setMicrophone(.capturing)

        XCTAssertEqual(liveActivity.lastMicrophone, .capturing)
    }

    func testLiveActivityContentStateCarriesPendingSharedMargin() throws {
        let original = Gate2LiveActivityAttributes.ContentState(
            title: "Pill",
            chapterTitle: "Opening",
            status: "paused",
            phase: "itemPlayback",
            progressPercent: 42,
            isRecording: false,
            sharedMarginSenderLabel: "Cole"
        )

        let decoded = try JSONDecoder().decode(
            Gate2LiveActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.sharedMarginSenderLabel, "Cole")
    }

    func testLiveActivityContentStateCarriesSharedMarginNavigationKind() throws {
        let original = Gate2LiveActivityAttributes.ContentState(
            title: "Pill",
            chapterTitle: "Opening",
            nextChapterTitle: "Shared Margin",
            nextChapterId: "received-margin-7",
            nextNavigationKind: .sharedMargin,
            status: "playing",
            phase: "itemPlayback",
            progressPercent: 20,
            isRecording: false
        )

        let decoded = try JSONDecoder().decode(
            Gate2LiveActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.nextNavigationKind, .sharedMargin)
        XCTAssertEqual(decoded.nextChapterId, "received-margin-7")
    }

    func testLiveActivityUsesOpenSpaceForTheFollowingSourceChapter() throws {
        var snapshot = compactSnapshot(
            targetType: TargetType.itemTextTTS.rawValue,
            availableCommands: [.beginInterjection],
            durationMs: nil
        )
        snapshot.chapterTitle = "Inputs"
        snapshot.sourceProgressPercent = 9
        snapshot.timeline = [
            CompactTimelineEntry(id: "source-inputs", kind: "source_chapter", title: "Inputs", chapterId: "inputs", percent: 0, isCurrent: true),
            CompactTimelineEntry(id: "note", kind: "interjection", title: "Interjection", percent: 8),
            CompactTimelineEntry(id: "source-chain", kind: "source_chapter", title: "Chain of Thought", chapterId: "chain", percent: 27)
        ]

        let next = try XCTUnwrap(Gate2LiveActivityPolicy.nextSourceChapter(from: snapshot))
        XCTAssertEqual(next.title, "Chain of Thought")
        XCTAssertEqual(next.chapterId, "chain")

        let url = Gate2CompactCommandURL.url(command: CompactControlCommand.jumpToChapter.rawValue, chapterId: next.chapterId)
        XCTAssertEqual(Gate2CompactCommandURL.command(from: url), CompactControlCommand.jumpToChapter.rawValue)
        XCTAssertEqual(Gate2CompactCommandURL.chapterId(from: url), "chain")
    }

    func testLiveActivityFindsNextNativeAudioChapterAndStopsAtTheLastChapter() {
        var snapshot = compactSnapshot(
            targetType: TargetType.transcriptBackedMedia.rawValue,
            availableCommands: [.beginInterjection],
            durationMs: 120_000
        )
        snapshot.chapterTitle = "Opening"
        snapshot.timeline = [
            CompactTimelineEntry(id: "source-opening", kind: "source_chapter", title: "Opening", chapterId: "opening", percent: 0, isCurrent: true),
            CompactTimelineEntry(id: "source-analysis", kind: "source_chapter", title: "Analysis", chapterId: "analysis", percent: 50)
        ]

        XCTAssertEqual(Gate2LiveActivityPolicy.nextSourceChapter(from: snapshot)?.chapterId, "analysis")

        snapshot.timeline[0].isCurrent = false
        snapshot.timeline[1].isCurrent = true
        snapshot.chapterTitle = "Analysis"
        XCTAssertNil(Gate2LiveActivityPolicy.nextSourceChapter(from: snapshot))
    }

    func testLiveActivityOrdersPublisherChaptersAndSharedMarginsBySourcePosition() throws {
        var snapshot = compactSnapshot(
            targetType: TargetType.transcriptBackedMedia.rawValue,
            availableCommands: [.beginInterjection],
            durationMs: 120_000
        )
        snapshot.sourceProgressPercent = 10
        snapshot.timeline = [
            CompactTimelineEntry(id: "source-opening", kind: "source_chapter", title: "Opening", chapterId: "opening", percent: 0, isCurrent: true),
            CompactTimelineEntry(id: "source-analysis", kind: "source_chapter", title: "Analysis", chapterId: "analysis", percent: 60)
        ]
        let nearMargin = Gate2LiveActivityNavigationEntry(
            kind: .sharedMargin,
            title: "Shared Margin",
            targetID: "margin-near",
            positionPercent: 35
        )
        let farMargin = Gate2LiveActivityNavigationEntry(
            kind: .sharedMargin,
            title: "Shared Margin",
            targetID: "margin-far",
            positionPercent: 80
        )

        let marginFirst = try XCTUnwrap(
            Gate2LiveActivityPolicy.nextNavigationEntry(
                from: snapshot,
                upcomingSharedMargins: [farMargin, nearMargin]
            )
        )
        XCTAssertEqual(marginFirst.kind, .sharedMargin)
        XCTAssertEqual(marginFirst.targetID, "margin-near")

        let chapterFirst = try XCTUnwrap(
            Gate2LiveActivityPolicy.nextNavigationEntry(
                from: snapshot,
                upcomingSharedMargins: [farMargin]
            )
        )
        XCTAssertEqual(chapterFirst.kind, .sourceChapter)
        XCTAssertEqual(chapterFirst.targetID, "analysis")

        snapshot.timeline = []
        XCTAssertEqual(
            Gate2LiveActivityPolicy.nextNavigationEntry(
                from: snapshot,
                upcomingSharedMargins: [nearMargin]
            )?.targetID,
            "margin-near"
        )
    }

    func testSharedMarginNavigationMovesToVerifiedAnchorAndPublishesPrompt() {
        let liveActivity = RecordingLiveActivityController()
        let controller = Gate2CompactControlController(liveActivity: liveActivity)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            gate2CompactControls: controller
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let layer = ImportedCommentaryLayer(
            id: "layer-received",
            itemId: "item-pill",
            packageDigest: "digest-received",
            packageId: "package-received",
            itemIdentity: SharedItemIdentity(itemType: .text, title: "You Can't Inspect the Pill"),
            displayLabel: "Cole",
            importedAt: Date(timeIntervalSince1970: 42),
            sourceResolutionStatus: .resolved,
            isEnabled: true,
            isMuted: true,
            revealMode: .companion
        )
        let record = ImportedCommentaryInterjection(
            id: "received-margin-7",
            layerId: layer.id,
            packageScopedId: "margin-7",
            createdAt: Date(timeIntervalSince1970: 43),
            anchorEvidence: PortableAnchorEvidence(anchorType: .text, startChar: 120, endChar: 140),
            approvedTranscript: "Remember this part.",
            resolution: ImportedAnchorResolution(
                evidenceClass: .articleTextVerified,
                localStartChar: 120,
                localEndChar: 140,
                confidence: 1
            )
        )
        model.selectedItem.importedCommentaryLayers = [layer]
        model.selectedItem.importedCommentaryInterjections = [layer.id: [record]]

        XCTAssertTrue(
            model.handleGate2CompactApplicationCommand(
                Gate2CompactApplicationCommand.jumpToSharedMargin,
                targetID: record.id
            )
        )

        XCTAssertEqual(model.pendingImportedCommentary?.id, record.id)
        XCTAssertEqual(model.pendingImportedCommentary?.senderLabel, "Cole")
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(liveActivity.lastSharedMarginPrompt?.senderLabel, "Cole")
        XCTAssertEqual(model.diagnostics["lastSharedMarginNavigation"], "opened:received-margin-7")
    }

    func testLiveActivityPolicyRejectsFinishedAndStaleSessions() {
        let active = compactSnapshot(
            targetType: TargetType.itemTextTTS.rawValue,
            availableCommands: [.togglePlayPause],
            durationMs: nil
        )
        var finished = active
        finished.phase = .finished
        finished.status = .idle

        XCTAssertTrue(Gate2LiveActivityPolicy.isEligible(active))
        XCTAssertTrue(Gate2LiveActivityPolicy.shouldMaintain(active, adoptedSessionId: nil))
        var paused = active
        paused.status = .paused
        XCTAssertFalse(Gate2LiveActivityPolicy.shouldMaintain(paused, adoptedSessionId: nil))
        XCTAssertTrue(Gate2LiveActivityPolicy.shouldMaintain(paused, adoptedSessionId: "session-pill"))
        var recording = active
        recording.isRecording = true
        XCTAssertTrue(Gate2LiveActivityPolicy.shouldMaintain(recording, adoptedSessionId: nil))
        XCTAssertFalse(Gate2LiveActivityPolicy.isEligible(finished))
        XCTAssertFalse(Gate2LiveActivityPolicy.shouldEnd(activitySessionId: "session-pill", currentSessionId: "session-pill"))
        XCTAssertTrue(Gate2LiveActivityPolicy.shouldEnd(activitySessionId: "session-old", currentSessionId: "session-pill"))
        XCTAssertTrue(Gate2LiveActivityPolicy.shouldEnd(activitySessionId: "session-pill", currentSessionId: nil))
        XCTAssertTrue(Gate2LiveActivityPolicy.shouldEndInactive(activitySessionId: "session-pill", activityId: "activity-1", inactiveSessionId: "session-pill", trackedActivityId: nil))
        XCTAssertFalse(Gate2LiveActivityPolicy.shouldEndInactive(activitySessionId: "session-new", activityId: "activity-2", inactiveSessionId: "session-pill", trackedActivityId: nil))
        XCTAssertTrue(Gate2LiveActivityPolicy.shouldEndInactive(activitySessionId: "session-any", activityId: "activity-1", inactiveSessionId: nil, trackedActivityId: "activity-1"))
    }

    /// C3 M1: a process killed in the background never runs `willTerminate`, so its activity is
    /// orphaned. The first idle pass after launch ends it even when it belongs to another session;
    /// later idle passes end only the inactive session's card. Drives the real controller over a
    /// fake card list (APO-05, #1291), so the flag's wiring is what is tested.
    func testFirstIdlePassAfterLaunchEndsActivitiesFromAnEarlierProcess() async {
        let list = FakeLiveActivityList()
        list.add(id: "activity-orphan", sessionId: "session-killed")
        let controller = Gate2LiveActivityController(system: list.system)
        let restoredButPaused = liveActivitySnapshot(sessionId: "session-restored", status: .paused)

        publish(restoredButPaused, to: controller)
        await controller.waitForPendingWork()
        XCTAssertEqual(list.log, ["end:activity-orphan"], "the first idle pass ends the killed process's card")
        XCTAssertEqual(controller.status, "ended")

        list.add(id: "activity-other", sessionId: "session-other")
        publish(restoredButPaused, to: controller)
        await controller.waitForPendingWork()
        XCTAssertEqual(list.log, ["end:activity-orphan"], "a later idle pass leaves another session's card alone")
        XCTAssertEqual(list.cardIds, ["activity-other"])
        XCTAssertEqual(controller.status, "not_ready")
    }

    /// Publishing ends every other session's card, so it counts as the launch sweep: the idle pass
    /// after it ends only the card it tracks.
    func testAPublishCountsAsTheFirstSweepOfTheProcess() async {
        let list = FakeLiveActivityList()
        list.add(id: "activity-mine", sessionId: "session-pill")
        let controller = Gate2LiveActivityController(system: list.system)

        publish(liveActivitySnapshot(sessionId: "session-pill", status: .playing), to: controller)
        await controller.waitForPendingWork()
        XCTAssertEqual(controller.status, "updated")

        list.add(id: "activity-other", sessionId: "session-other")
        publish(liveActivitySnapshot(sessionId: nil, status: .idle), to: controller)
        await controller.waitForPendingWork()
        XCTAssertEqual(list.log, ["update:activity-mine", "end:activity-mine"])
        XCTAssertEqual(list.cardIds, ["activity-other"])
        XCTAssertEqual(controller.status, "ended")
    }

    /// Publishing for a session updates its first card and ends the rest: a card already handed
    /// off to iOS (ended, still on screen), another session's card, and any duplicate.
    func testPublishEndsHandedOffCardsOtherSessionsAndDuplicates() async {
        let list = FakeLiveActivityList()
        list.add(id: "activity-handed-off", sessionId: "session-pill", state: .ended)
        list.add(id: "activity-first", sessionId: "session-pill")
        list.add(id: "activity-duplicate", sessionId: "session-pill")
        list.add(id: "activity-old", sessionId: "session-old")
        let controller = Gate2LiveActivityController(system: list.system)

        publish(liveActivitySnapshot(sessionId: "session-pill", status: .playing), to: controller)
        await controller.waitForPendingWork()

        XCTAssertEqual(list.log, [
            "end:activity-handed-off",
            "end:activity-old",
            "update:activity-first",
            "end:activity-duplicate"
        ])
        XCTAssertEqual(list.cardIds, ["activity-first"])
        XCTAssertEqual(controller.status, "updated_pruned_stale")
    }

    /// #2962: a podcast's card was staying on the Lock Screen over a live session's. While the session's running card
    /// is up, publishing removes the item's cards and requests nothing; once the session's card is gone, the next
    /// publish puts the item's card back.
    func testRunningLiveSessionHoldsTheItemsCardOffTheLockScreen() async {
        let list = FakeLiveActivityList()
        list.add(id: "activity-pill", sessionId: "session-pill")
        list.isLiveSessionCardShowing = true
        let controller = Gate2LiveActivityController(system: list.system)

        publish(liveActivitySnapshot(sessionId: "session-pill", status: .playing), to: controller)
        await controller.waitForPendingWork()
        XCTAssertEqual(list.log, ["end:activity-pill"])
        XCTAssertEqual(list.cardIds, [])
        XCTAssertEqual(controller.status, "held_for_live_session")

        publish(liveActivitySnapshot(sessionId: "session-pill", status: .paused), to: controller)
        await controller.waitForPendingWork()
        XCTAssertEqual(list.log, ["end:activity-pill"], "no request while the session runs")
        XCTAssertEqual(controller.status, "held_for_live_session")

        list.isLiveSessionCardShowing = false
        publish(liveActivitySnapshot(sessionId: "session-pill", status: .playing), to: controller)
        await controller.waitForPendingWork()
        XCTAssertEqual(list.log, ["end:activity-pill", "request:session-pill"])
        XCTAssertEqual(controller.status, "started")
    }

    /// A handed-off card can't be updated, so publishing replaces it with a new request.
    func testPublishReplacesAHandedOffCardWithANewOne() async {
        let list = FakeLiveActivityList()
        list.add(id: "activity-handed-off", sessionId: "session-pill", state: .ended)
        let controller = Gate2LiveActivityController(system: list.system)

        publish(liveActivitySnapshot(sessionId: "session-pill", status: .playing), to: controller)
        await controller.waitForPendingWork()

        XCTAssertEqual(list.log, ["end:activity-handed-off", "request:session-pill"])
        XCTAssertEqual(list.cardIds, ["requested-1"])
        XCTAssertEqual(controller.status, "started")
    }

    /// The hand-off ends live and stale cards with their content and a dismissal time, and
    /// leaves cards that are already ended.
    func testHandOffDismissalEndsLiveCardsAtTheGivenTime() async {
        let list = FakeLiveActivityList()
        list.add(id: "activity-live", sessionId: "session-pill")
        list.add(id: "activity-stale", sessionId: "session-pill", state: .stale)
        list.add(id: "activity-handed-off", sessionId: "session-old", state: .ended)
        let controller = Gate2LiveActivityController(system: list.system)
        let dismissAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

        await controller.handOffDismissal(at: dismissAt)

        XCTAssertEqual(list.log, ["handoff:activity-live", "handoff:activity-stale"])
        XCTAssertEqual(list.handOffDates, [dismissAt, dismissAt])
        XCTAssertEqual(controller.status, "handed_off")
    }

    /// C3 M1: a paused Live Activity carries a stale date and ends after the idle limit, then
    /// stays ended until listening resumes.
    func testPausedLiveActivityCarriesAStaleDateAndEndsAfterTheIdleLimit() {
        let clock = TestClock()
        let liveActivity = RecordingLiveActivityController()
        let controller = Gate2CompactControlController(
            liveActivity: liveActivity,
            now: { clock.now },
            notificationCenter: NotificationCenter()
        )
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            gate2CompactControls: controller
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertNil(liveActivity.lastStaleDate, "no stale date while playing")

        model.dispatchGate2CompactCommand(.pause)
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(liveActivity.lastStaleDate, clock.now.addingTimeInterval(LiveActivityLifecycle.pausedIdleLimit))

        let endsBeforeDeadline = liveActivity.endAllCallCount
        clock.now = clock.now.addingTimeInterval(LiveActivityLifecycle.pausedIdleLimit - 1)
        model.refreshLockScreenSurfacesForLifecycle()
        XCTAssertEqual(liveActivity.endAllCallCount, endsBeforeDeadline, "still inside the idle limit")

        clock.now = clock.now.addingTimeInterval(1)
        model.refreshLockScreenSurfacesForLifecycle()
        XCTAssertEqual(liveActivity.endAllCallCount, endsBeforeDeadline + 1)
        XCTAssertEqual(controller.diagnostics()["gate2LiveActivityLifecycle"], "ended_idle_limit")

        let publishesWhileEnded = liveActivity.publishCallCount
        model.refreshLockScreenSurfacesForLifecycle()
        XCTAssertEqual(liveActivity.publishCallCount, publishesWhileEnded, "a paused refresh doesn't bring it back")

        model.dispatchGate2CompactCommand(.play)
        XCTAssertGreaterThan(liveActivity.publishCallCount, publishesWhileEnded, "resuming shows it again")
        XCTAssertNil(liveActivity.lastStaleDate)
    }

    // MARK: Owner decision #193 (option 2): a locked pause hands the removal to iOS after the grace.

    private func makeLockedPauseHarness() -> (Gate1AppModel, Gate2CompactControlController, RecordingLiveActivityController, TestClock, TestAppState, NotificationCenter) {
        let clock = TestClock()
        let app = TestAppState()
        let center = NotificationCenter()
        let liveActivity = RecordingLiveActivityController()
        let controller = Gate2CompactControlController(
            liveActivity: liveActivity,
            now: { clock.now },
            notificationCenter: center,
            isAppInBackground: { app.isInBackground },
            isOtherAudioPlaying: { app.isOtherAudioPlaying },
            isPhoneCallActive: { app.isInCall },
            beginBackgroundTask: { _ in
                app.beganBackgroundTasks += 1
                return { app.endedBackgroundTasks += 1 }
            }
        )
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), gate2CompactControls: controller)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        return (model, controller, liveActivity, clock, app, center)
    }

    func testLockedPauseHandsTheRemovalToIOSAfterTheGrace() async {
        let (model, controller, liveActivity, clock, app, _) = makeLockedPauseHarness()
        let grace = LiveActivityLifecycle.lockedPauseGrace
        app.isInBackground = true // paused from AirPods or the Lock Screen
        let pausedAt = clock.now
        model.dispatchGate2CompactCommand(.pause)
        XCTAssertEqual(controller.diagnostics()["gate2LiveActivityLifecycle"], "hand_off_scheduled")
        XCTAssertEqual(app.beganBackgroundTasks, 1, "a background task keeps the app running through the grace")

        clock.now = pausedAt.addingTimeInterval(grace)
        await controller.handOffIfDue()
        XCTAssertEqual(liveActivity.handOffDates, [pausedAt.addingTimeInterval(LiveActivityLifecycle.pausedIdleLimit)],
                       "iOS removes the card at the 30-minute deadline")
        XCTAssertEqual(controller.diagnostics()["gate2LiveActivityLifecycle"], "handed_off_to_system")
        XCTAssertEqual(app.endedBackgroundTasks, app.beganBackgroundTasks, "the background task is always ended")

        let publishes = liveActivity.publishCallCount
        model.refreshLockScreenSurfacesForLifecycle()
        XCTAssertEqual(liveActivity.publishCallCount, publishes, "a paused refresh doesn't request a new card")
        model.dispatchGate2CompactCommand(.play)
        XCTAssertGreaterThan(liveActivity.publishCallCount, publishes, "resuming asks for a card again")
    }

    func testQuickLockedPauseAndResumeKeepsTheCard() async {
        let (model, controller, liveActivity, clock, app, _) = makeLockedPauseHarness()
        app.isInBackground = true
        let pausedAt = clock.now
        model.dispatchGate2CompactCommand(.pause)
        clock.now = pausedAt.addingTimeInterval(8)
        model.dispatchGate2CompactCommand(.play)
        XCTAssertEqual(app.endedBackgroundTasks, app.beganBackgroundTasks, "resuming cancels the pending hand-off")

        clock.now = pausedAt.addingTimeInterval(LiveActivityLifecycle.lockedPauseGrace + 1)
        await controller.handOffIfDue()
        XCTAssertTrue(liveActivity.handOffDates.isEmpty)
    }

    func testPhoneCallPauseNeverHandsOffEitherOrder() async {
        let grace = LiveActivityLifecycle.lockedPauseGrace
        let began: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]

        // The interruption is reported, then the pause arrives.
        let (model, controller, liveActivity, clock, app, center) = makeLockedPauseHarness()
        app.isInBackground = true
        app.isInCall = true
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: began)
        let pausedAt = clock.now
        model.dispatchGate2CompactCommand(.pause)
        XCTAssertEqual(app.beganBackgroundTasks, 0, "no hand-off is scheduled for a call")
        clock.now = pausedAt.addingTimeInterval(grace)
        await controller.handOffIfDue()
        XCTAssertTrue(liveActivity.handOffDates.isEmpty, "the card stays to resume after the call")

        // The pause arrives first; the interruption cancels the scheduled hand-off.
        let (model2, controller2, liveActivity2, clock2, app2, center2) = makeLockedPauseHarness()
        app2.isInBackground = true
        model2.dispatchGate2CompactCommand(.pause)
        XCTAssertEqual(app2.beganBackgroundTasks, 1)
        app2.isInCall = true
        center2.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: began)
        XCTAssertEqual(app2.endedBackgroundTasks, 1)
        clock2.now = clock2.now.addingTimeInterval(grace)
        await controller2.handOffIfDue()
        XCTAssertTrue(liveActivity2.handOffDates.isEmpty)
    }

    // MARK: #245: another app took over the audio.

    /// The owner's original complaint: the card stayed after switching to another audio app.
    func testAnotherAppTakingTheAudioEndsTheCardWithinSeconds() {
        let (model, controller, liveActivity, clock, app, center) = makeLockedPauseHarness()
        app.isInBackground = true
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ])
        model.dispatchGate2CompactCommand(.pause)
        XCTAssertEqual(app.beganBackgroundTasks, 1, "the app keeps running to watch for the other app")
        let endsBefore = liveActivity.endAllCallCount

        app.isOtherAudioPlaying = true // Spotify is playing
        clock.now = clock.now.addingTimeInterval(LiveActivityLifecycle.otherAudioCheckInterval)
        XCTAssertTrue(controller.checkForOtherAudio())
        XCTAssertEqual(liveActivity.endAllCallCount, endsBefore + 1, "the card leaves at the first check")
        XCTAssertEqual(controller.diagnostics()["gate2LiveActivityLifecycle"], "ended_other_audio_took_over")
        XCTAssertEqual(app.endedBackgroundTasks, app.beganBackgroundTasks)

        let publishes = liveActivity.publishCallCount
        model.refreshLockScreenSurfacesForLifecycle()
        XCTAssertEqual(liveActivity.publishCallCount, publishes, "a paused refresh doesn't bring it back")
    }

    func testLockedPauseThenAnotherAppEndsTheCard() {
        let (model, controller, liveActivity, _, app, _) = makeLockedPauseHarness()
        app.isInBackground = true
        model.dispatchGate2CompactCommand(.pause) // paused from AirPods
        XCTAssertFalse(controller.checkForOtherAudio(), "nothing else playing: the card stays")
        let endsBefore = liveActivity.endAllCallCount
        app.isOtherAudioPlaying = true
        XCTAssertTrue(controller.checkForOtherAudio())
        XCTAssertEqual(liveActivity.endAllCallCount, endsBefore + 1)
    }

    func testPhoneCallKeepsTheCardEvenWhileOtherAudioIsReported() {
        let (model, controller, liveActivity, _, app, center) = makeLockedPauseHarness()
        app.isInBackground = true
        app.isInCall = true
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ])
        model.dispatchGate2CompactCommand(.pause)
        let endsBefore = liveActivity.endAllCallCount
        app.isOtherAudioPlaying = true
        XCTAssertFalse(controller.checkForOtherAudio())
        XCTAssertEqual(liveActivity.endAllCallCount, endsBefore, "the card stays to resume after the call")
    }

    func testQuickPauseInOurOwnAppKeepsTheCard() {
        let (model, controller, liveActivity, _, app, _) = makeLockedPauseHarness()
        model.dispatchGate2CompactCommand(.pause) // on screen, in our app
        let endsBefore = liveActivity.endAllCallCount
        app.isOtherAudioPlaying = true
        XCTAssertFalse(controller.checkForOtherAudio())
        XCTAssertEqual(liveActivity.endAllCallCount, endsBefore)
        XCTAssertEqual(app.beganBackgroundTasks, 0, "no watch while the app is on screen")
    }

    func testPauseInTheAppHandsOffOnlyOnceTheAppGoesToTheBackground() async {
        let (model, controller, liveActivity, clock, app, center) = makeLockedPauseHarness()
        let pausedAt = clock.now
        model.dispatchGate2CompactCommand(.pause)
        XCTAssertEqual(app.beganBackgroundTasks, 0, "paused on screen: the app manages the card")

        app.isInBackground = true
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(app.beganBackgroundTasks, 1, "locking the phone starts the grace")

        app.isInBackground = false
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(app.endedBackgroundTasks, 1, "coming back cancels it")
        clock.now = pausedAt.addingTimeInterval(LiveActivityLifecycle.lockedPauseGrace + 1)
        await controller.handOffIfDue()
        XCTAssertTrue(liveActivity.handOffDates.isEmpty)
    }

    /// C3 M1: when another app keeps the audio (the interruption ends without `shouldResume`), the
    /// paused activity ends at once. A phone call ends with `shouldResume`, so the activity stays.
    func testInterruptionEndingWithoutResumeEndsThePausedLiveActivity() {
        let center = NotificationCenter()
        let liveActivity = RecordingLiveActivityController()
        let controller = Gate2CompactControlController(liveActivity: liveActivity, notificationCenter: center)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            gate2CompactControls: controller
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.dispatchGate2CompactCommand(.pause)
        let endsBefore = liveActivity.endAllCallCount

        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
        ])
        XCTAssertEqual(liveActivity.endAllCallCount, endsBefore, "a phone call keeps the activity")

        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: UInt(0)
        ])
        XCTAssertEqual(liveActivity.endAllCallCount, endsBefore + 1)
        XCTAssertEqual(controller.diagnostics()["gate2LiveActivityLifecycle"], "ended_interruption_without_resume")
    }

    func testLiveActivityPolicyRetainsInterjectionButRemovesSuspensionUnsafeControls() {
        let snapshot = compactSnapshot(
            targetType: TargetType.transcriptBackedMedia.rawValue,
            availableCommands: [
                .togglePlayPause,
                .skipBack,
                .skipForward,
                .skimBackward,
                .skimForward,
                .setPlaybackRate,
                .beginInterjection,
                .finishInterjection,
                .generateInterjectionSummary
            ],
            durationMs: 120_000
        )

        XCTAssertEqual(
            Gate2LiveActivityPolicy.availableCommands(from: snapshot),
            [.skimBackward, .skimForward, .beginInterjection, .finishInterjection]
        )
    }

    func testCompactControllerOverlaysAppOwnedSkimReadinessWithoutRemappingTimeSkips() throws {
        let profile = RuntimeCapabilityProfile(
            id: "skim-live-activity",
            displayName: "Skim Live Activity",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "timeline": ["chapter_timing"],
                "remoteControl": ["display_snapshot", "send_transport_commands"]
            ]
        )
        let repository = InMemorySessionRepository(items: [
            "episode": Item(
                id: "episode",
                title: "Episode",
                mediaType: "audio",
                text: nil,
                externalReference: nil,
                status: "ready",
                media: ItemMedia(
                    sourceType: .nativeMediaFile,
                    url: "file:///tmp/episode.m4a",
                    durationMs: 600_000
                )
            )
        ])
        let engine = SessionEngine(
            profile: profile,
            repository: repository,
            audio: NoopAudioPlaybackClient()
        )
        _ = try engine.startSession(itemId: "episode")
        let controller = Gate2CompactControlController(liveActivity: RecordingLiveActivityController())
        controller.configure(
            canonicalRuntime: engine,
            surfaceProfile: profile,
            skipUnit: "time_15s",
            commandHandler: { _, _, _, _, _ in }
        )
        var appSnapshot = engine.snapshot
        appSnapshot.canSkimBackward = true
        appSnapshot.canSkimForward = true
        controller.update(snapshot: appSnapshot)

        XCTAssertTrue(controller.snapshot?.availableCommands.contains(.skimBackward) == true)
        XCTAssertTrue(controller.snapshot?.availableCommands.contains(.skimForward) == true)
        XCTAssertTrue(controller.snapshot?.availableCommands.contains(.skipBack) == true)
        XCTAssertTrue(controller.snapshot?.availableCommands.contains(.skipForward) == true)

        // #115: the destinations ride along for the Lock Screen, only for a Skim that is offered.
        controller.update(snapshot: appSnapshot, skimForwardDestinationMs: 90_000, skimBackwardDestinationMs: 30_000)
        XCTAssertEqual(controller.snapshot?.skimForwardDestinationMs, 90_000)
        XCTAssertEqual(controller.snapshot?.skimBackwardDestinationMs, 30_000)
        appSnapshot.canSkimForward = false
        controller.update(snapshot: appSnapshot, skimForwardDestinationMs: 90_000, skimBackwardDestinationMs: 30_000)
        XCTAssertFalse(controller.snapshot?.availableCommands.contains(.skimForward) == true)
        XCTAssertNil(controller.snapshot?.skimForwardDestinationMs, "a hidden Skim shows no stale time")
        XCTAssertEqual(controller.snapshot?.skimBackwardDestinationMs, 30_000)

        // #1044 APO-13: each Skim follows its own readiness, and neither is offered while recording.
        appSnapshot.canSkimBackward = false
        appSnapshot.canSkimForward = true
        controller.update(snapshot: appSnapshot)
        XCTAssertFalse(controller.snapshot?.availableCommands.contains(.skimBackward) == true,
                       "Skim back is offered although the app says it can't skim back")
        XCTAssertTrue(controller.snapshot?.availableCommands.contains(.skimForward) == true)

        appSnapshot.canSkimBackward = true
        appSnapshot.isRecording = true
        controller.update(snapshot: appSnapshot)
        XCTAssertFalse(controller.snapshot?.availableCommands.contains(.skimBackward) == true,
                       "Skim back is offered while a Margin is recording")
        XCTAssertFalse(controller.snapshot?.availableCommands.contains(.skimForward) == true,
                       "Skim forward is offered while a Margin is recording")
        XCTAssertTrue(controller.snapshot?.availableCommands.contains(.skipBack) == true,
                      "the overlay only removes Skim; time skips are not its to change")
    }

    /// #2181: the Lock Screen card of a podcast or publisher recording belongs to the player. The compact controls
    /// republish on every lifecycle change and end() on a Margin's voice, and used to overwrite or clear that card.
    private func makeNativeMediaCompactControls() throws -> (controller: Gate2CompactControlController, snapshot: SessionSnapshot) {
        let profile = RuntimeCapabilityProfile(
            id: "now-playing-ownership",
            displayName: "Now Playing ownership",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "timeline": ["chapter_timing"],
                "remoteControl": ["display_snapshot", "send_transport_commands"]
            ]
        )
        let repository = InMemorySessionRepository(items: [
            "episode": Item(
                id: "episode",
                title: "Episode",
                mediaType: "audio",
                text: nil,
                externalReference: nil,
                status: "ready",
                media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/episode.m4a", durationMs: 600_000)
            )
        ])
        let engine = SessionEngine(profile: profile, repository: repository, audio: NoopAudioPlaybackClient())
        _ = try engine.startSession(itemId: "episode")
        let controller = Gate2CompactControlController(liveActivity: RecordingLiveActivityController())
        controller.configure(
            canonicalRuntime: engine,
            surfaceProfile: profile,
            skipUnit: "time_15s",
            commandHandler: { _, _, _, _, _ in }
        )
        return (controller, engine.snapshot)
    }

    private func releaseNowPlayingLedger() {
        for writer in [NowPlayingWriter.mediaPlayer, .compactControls, .sharedMargin] {
            NowPlayingInfoOwnership.shared.clear(as: writer)
        }
    }

    func testCompactControlsNeverOverwriteOrClearTheMediaPlayersNowPlayingCard() throws {
        releaseNowPlayingLedger()
        defer { releaseNowPlayingLedger() }
        let (controller, snapshot) = try makeNativeMediaCompactControls()
        let ledger = NowPlayingInfoOwnership.shared
        ledger.write([MPMediaItemPropertyTitle: "Held by the player"], as: .mediaPlayer)

        controller.update(snapshot: snapshot)
        controller.reconcileLiveActivities() // the move to the background
        controller.setNowPlayingEnabled(false) // a Margin's voice takes the transport
        controller.endLiveActivities()

        XCTAssertEqual(ledger.currentHolder, .mediaPlayer)
        XCTAssertEqual(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String,
            "Held by the player",
            "the compact controls replaced or removed the player's card; recent: \(ledger.summary())"
        )
    }

    func testAFinishedSessionTakesDownTheCardThePlayerHolds() {
        releaseNowPlayingLedger()
        defer { releaseNowPlayingLedger() }
        let ledger = NowPlayingInfoOwnership.shared
        var snapshot = compactSnapshot(
            targetType: TargetType.transcriptBackedMedia.rawValue,
            availableCommands: [.togglePlayPause],
            durationMs: 120_000
        )

        ledger.write([MPMediaItemPropertyTitle: "Held by the player"], as: .mediaPlayer)
        Gate2EndedSessionNowPlaying.clearPlayerCard(for: snapshot)
        XCTAssertEqual(ledger.currentHolder, .mediaPlayer, "a playing session keeps the player's card")

        snapshot.phase = .finished
        Gate2EndedSessionNowPlaying.clearPlayerCard(for: snapshot)
        XCTAssertNil(ledger.currentHolder, ledger.summary())
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    func testCompactControlsFillTheNativeMediaCardWhenThePlayerHasNoneAndTakeItDownAtTheEnd() throws {
        releaseNowPlayingLedger()
        defer { releaseNowPlayingLedger() }
        let (controller, snapshot) = try makeNativeMediaCompactControls()
        let ledger = NowPlayingInfoOwnership.shared

        controller.update(snapshot: snapshot)
        XCTAssertEqual(ledger.currentHolder, .compactControls, ledger.summary())
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Episode")

        controller.endLiveActivities()
        XCTAssertNil(ledger.currentHolder)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    func testNowPlayingPoliciesKeepNativeMediaMetadataWithoutSharingCommandOwnership() {
        let liveSpeech = compactSnapshot(
            targetType: TargetType.itemTextTTS.rawValue,
            availableCommands: [.togglePlayPause, .skipBack, .skipForward],
            durationMs: nil
        )
        let nativeMedia = compactSnapshot(
            targetType: TargetType.transcriptBackedMedia.rawValue,
            availableCommands: [.togglePlayPause, .skipBack, .skipForward],
            durationMs: 120_000
        )
        var finishedSpeech = liveSpeech
        finishedSpeech.phase = .finished
        finishedSpeech.status = .idle
        var finishedMedia = nativeMedia
        finishedMedia.phase = .finished
        finishedMedia.status = .idle
        let assistantSpeech = compactSnapshot(
            targetType: TargetType.assistantTurnTTS.rawValue,
            availableCommands: [.togglePlayPause, .skipBack, .skipForward, .setPlaybackRate],
            durationMs: nil
        )

        XCTAssertTrue(Gate2LiveSpeechNowPlayingPolicy.shouldPublish(liveSpeech))
        XCTAssertTrue(Gate2LiveSpeechNowPlayingPolicy.shouldPublish(assistantSpeech))
        XCTAssertTrue(Gate2NowPlayingCommandAvailability(snapshot: assistantSpeech).canPause)
        XCTAssertFalse(Gate2LiveSpeechNowPlayingPolicy.shouldPublish(nativeMedia))
        XCTAssertFalse(Gate2LiveSpeechNowPlayingPolicy.shouldPublish(finishedSpeech))
        XCTAssertTrue(Gate2NativeMediaNowPlayingPolicy.shouldPublish(nativeMedia))
        XCTAssertFalse(Gate2NativeMediaNowPlayingPolicy.shouldPublish(liveSpeech))
        XCTAssertFalse(Gate2NativeMediaNowPlayingPolicy.shouldPublish(finishedMedia))
    }

    func testLifecycleRefreshRepublishesCompactAndLockScreenSurfaces() {
        let liveActivity = RecordingLiveActivityController()
        let controller = Gate2CompactControlController(liveActivity: liveActivity)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            gate2CompactControls: controller
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let priorCount = liveActivity.publishCallCount

        model.refreshLockScreenSurfacesForLifecycle()

        XCTAssertEqual(liveActivity.publishCallCount, priorCount + 1)
        XCTAssertEqual(model.diagnostics["lockScreenLifecycleRefresh"], model.snapshot.targetType ?? "none")
    }

    func testSessionMixingPolicyCanRelinquishAndRestoreNowPlaying() throws {
        let profile = RuntimeCapabilityProfile(
            id: "mixing-now-playing",
            displayName: "Mixing Now Playing",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["tts"],
                "remoteControl": ["display_snapshot", "send_transport_commands"]
            ]
        )
        let repository = InMemorySessionRepository(items: [
            "text": Item(
                id: "text",
                title: "Text",
                mediaType: "text",
                text: "Listen while music continues.",
                externalReference: nil,
                status: "ready"
            )
        ])
        let engine = SessionEngine(profile: profile, repository: repository, audio: NoopAudioPlaybackClient())
        let started = try engine.startSession(itemId: "text")
        let sessionId = try XCTUnwrap(started.sessionId, "the text session did not start")
        let controller = Gate2CompactControlController(liveActivity: RecordingLiveActivityController())
        controller.configure(
            canonicalRuntime: engine,
            surfaceProfile: profile,
            skipUnit: "paragraph",
            commandHandler: { _, _, _, _, _ in }
        )

        controller.setNowPlayingEnabled(false)
        XCTAssertEqual(controller.diagnostics()["gate2NowPlayingEnabled"], "false")
        XCTAssertEqual(controller.diagnostics()["gate2NowPlaying"], "ended")

        controller.setNowPlayingEnabled(true)
        XCTAssertEqual(controller.diagnostics()["gate2NowPlayingEnabled"], "true")
        // #1044 APO-07: turning mixing off again must bring the Lock Screen card back, not just flip the flag.
        let restored = controller.diagnostics()["gate2NowPlaying"] ?? "missing"
        XCTAssertTrue(restored.hasPrefix("live_speech_"), "Now Playing was not republished after the restore: \(restored)")
        XCTAssertEqual(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String,
            sessionId,
            "the system Now Playing card does not show this session again"
        )
    }

    func testPeriodicCompactRefreshIgnoresRawElapsedTimeButRetainsMeaningfulChanges() {
        var first = compactSnapshot(
            targetType: TargetType.transcriptBackedMedia.rawValue,
            availableCommands: [.togglePlayPause, .seekToMediaTime],
            durationMs: 120_000
        )
        var elapsedOnly = first
        elapsedOnly.currentMediaTimeMs = 1_500
        var progressed = elapsedOnly
        progressed.currentPlaybackProgressPercent = 11

        XCTAssertTrue(Gate2CompactControlController.hasEquivalentSurfaceState(first, elapsedOnly))
        XCTAssertFalse(Gate2CompactControlController.hasEquivalentSurfaceState(first, progressed))

        first.status = .paused
        XCTAssertFalse(Gate2CompactControlController.hasEquivalentSurfaceState(first, elapsedOnly))
    }

    private func liveActivitySnapshot(sessionId: String?, status: PlaybackStatus) -> CompactControlSnapshot {
        var snapshot = compactSnapshot(
            targetType: TargetType.itemTextTTS.rawValue,
            availableCommands: [.pause],
            durationMs: 120_000
        )
        snapshot.sessionId = sessionId
        snapshot.status = status
        return snapshot
    }

    private func publish(_ snapshot: CompactControlSnapshot, to controller: Gate2LiveActivityController) {
        controller.publish(
            snapshot,
            staleDate: nil,
            sharedMarginPrompt: nil,
            upcomingSharedMargins: [],
            microphone: .capturing
        )
    }

    private func compactSnapshot(
        targetType: String,
        availableCommands: [CompactControlCommand],
        durationMs: Int?
    ) -> CompactControlSnapshot {
        CompactControlSnapshot(
            sessionId: "session-pill",
            itemId: "item-pill",
            targetType: targetType,
            targetId: "item-pill",
            title: "Pill",
            chapterTitle: "Opening",
            status: .playing,
            phase: .itemPlayback,
            progressPercent: 10,
            currentPlaybackProgressPercent: 10,
            sourceProgressPercent: 10,
            currentMediaTimeMs: 1_000,
            currentPlaybackDurationMs: durationMs,
            playbackRate: 1,
            isRecording: false,
            pendingAiJobCount: 0,
            pendingAiJobKind: nil,
            pendingAiJobStatus: nil,
            lastUserTurnType: nil,
            exposedCommands: CompactControlCommand.allCases,
            availableCommands: availableCommands,
            compactSurfaceReady: true,
            surfaceProfileId: "lock-screen-widget"
        )
    }

    private func restoreUserDefault(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
}

@MainActor
private final class RecordingLiveActivityController: Gate2LiveActivityControlling {
    private(set) var status = "recording"
    private(set) var endAllCallCount = 0
    private(set) var publishCallCount = 0
    private(set) var lastStaleDate: Date?
    private(set) var lastSharedMarginPrompt: Gate2SharedMarginActivityPrompt?
    private(set) var lastUpcomingSharedMargins: [Gate2LiveActivityNavigationEntry] = []
    private(set) var lastMicrophone = Gate2LiveActivityMicrophone.capturing

    func publish(
        _ snapshot: CompactControlSnapshot,
        staleDate: Date?,
        sharedMarginPrompt: Gate2SharedMarginActivityPrompt?,
        upcomingSharedMargins: [Gate2LiveActivityNavigationEntry],
        microphone: Gate2LiveActivityMicrophone
    ) {
        publishCallCount += 1
        lastMicrophone = microphone
        lastStaleDate = staleDate
        lastSharedMarginPrompt = sharedMarginPrompt
        lastUpcomingSharedMargins = upcomingSharedMargins
    }

    func endAll() {
        endAllCallCount += 1
        status = "ended"
    }

    private(set) var handOffDates: [Date] = []

    func handOffDismissal(at date: Date) async {
        handOffDates.append(date)
        status = "handed_off"
    }
}

/// The Live Activity list the real `Gate2LiveActivityController` sees in tests (APO-05). Ending a
/// card immediately takes it off the list, as ActivityKit does; a hand-off leaves it ended.
private final class FakeLiveActivityList: @unchecked Sendable {
    private let lock = NSLock()
    private var cards: [(id: String, sessionId: String, state: ActivityState)] = []
    private var events: [String] = []
    private var dismissals: [Date] = []
    private var requestCount = 0
    private var liveSessionCardShowing = false

    /// Whether a live session's running card is up, as the controller's system reports it (#2962).
    var isLiveSessionCardShowing: Bool {
        get { lock.withLock { liveSessionCardShowing } }
        set { lock.withLock { liveSessionCardShowing = newValue } }
    }

    var log: [String] { lock.withLock { events } }
    var cardIds: [String] { lock.withLock { cards.map(\.id) } }
    var handOffDates: [Date] { lock.withLock { dismissals } }

    var system: Gate2LiveActivitySystem {
        Gate2LiveActivitySystem(
            areActivitiesEnabled: { true },
            activities: { [self] in
                lock.withLock { cards.map { FakeLiveActivityCard(id: $0.id, sessionId: $0.sessionId, list: self) } }
            },
            request: { [self] sessionId, _, _ in
                lock.withLock {
                    requestCount += 1
                    let id = "requested-\(requestCount)"
                    cards.append((id, sessionId, .active))
                    events.append("request:\(sessionId)")
                    return id
                }
            },
            isLiveSessionCardShowing: { [self] in isLiveSessionCardShowing }
        )
    }

    func add(id: String, sessionId: String, state: ActivityState = .active) {
        lock.withLock { cards.append((id, sessionId, state)) }
    }

    fileprivate func state(of id: String) -> ActivityState {
        lock.withLock { cards.first { $0.id == id }?.state ?? .ended }
    }

    fileprivate func record(_ event: String, removing id: String? = nil, handingOff handOffId: String? = nil, at date: Date? = nil) {
        lock.withLock {
            events.append(event)
            if let id { cards.removeAll { $0.id == id } }
            if let handOffId, let index = cards.firstIndex(where: { $0.id == handOffId }) {
                cards[index].state = .ended
            }
            if let date { dismissals.append(date) }
        }
    }
}

private struct FakeLiveActivityCard: Gate2LiveActivityCard {
    let id: String
    let sessionId: String
    let list: FakeLiveActivityList

    var state: ActivityState { list.state(of: id) }

    func update(_ state: Gate2LiveActivityAttributes.ContentState, staleDate: Date?) async {
        list.record("update:\(id)")
    }

    func endImmediately() async {
        list.record("end:\(id)", removing: id)
    }

    func endKeepingContent(dismissAt date: Date) async {
        list.record("handoff:\(id)", handingOff: id, at: date)
    }
}

@MainActor
private final class TestAppState {
    var isInBackground = false
    var isOtherAudioPlaying = false
    var isInCall = false
    var beganBackgroundTasks = 0
    var endedBackgroundTasks = 0
}
