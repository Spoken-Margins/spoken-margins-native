import XCTest
@testable import SessionKit
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

        let mediaSnapshot = compactSnapshot(
            targetType: TargetType.transcriptBackedMedia.rawValue,
            availableCommands: [.togglePlayPause, .seekToMediaTime, .setPlaybackRate],
            durationMs: 120_000
        )
        let mediaAvailability = Gate2NowPlayingCommandAvailability(snapshot: mediaSnapshot)

        XCTAssertTrue(mediaAvailability.canSeek)
        XCTAssertTrue(mediaAvailability.canSetPlaybackRate)
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
        XCTAssertFalse(Gate2LiveActivityPolicy.isEligible(finished))
        XCTAssertFalse(Gate2LiveActivityPolicy.shouldEnd(activitySessionId: "session-pill", currentSessionId: "session-pill"))
        XCTAssertTrue(Gate2LiveActivityPolicy.shouldEnd(activitySessionId: "session-old", currentSessionId: "session-pill"))
        XCTAssertTrue(Gate2LiveActivityPolicy.shouldEnd(activitySessionId: "session-pill", currentSessionId: nil))
        XCTAssertTrue(Gate2LiveActivityPolicy.shouldEndInactive(activitySessionId: "session-pill", activityId: "activity-1", inactiveSessionId: "session-pill", trackedActivityId: nil))
        XCTAssertFalse(Gate2LiveActivityPolicy.shouldEndInactive(activitySessionId: "session-new", activityId: "activity-2", inactiveSessionId: "session-pill", trackedActivityId: nil))
        XCTAssertTrue(Gate2LiveActivityPolicy.shouldEndInactive(activitySessionId: "session-any", activityId: "activity-1", inactiveSessionId: nil, trackedActivityId: "activity-1"))
    }

    func testLiveSpeechNowPlayingPolicyDoesNotCompeteWithNativeMedia() {
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
private final class RecordingLiveActivityController: Gate2LiveActivityControlling {
    private(set) var status = "recording"
    private(set) var endAllCallCount = 0

    func publish(_ snapshot: CompactControlSnapshot) {}

    func endAll() {
        endAllCallCount += 1
        status = "ended"
    }
}
