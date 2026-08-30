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

    func testLiveActivityPolicyRetainsInterjectionButRemovesSuspensionUnsafeControls() {
        let snapshot = compactSnapshot(
            targetType: TargetType.transcriptBackedMedia.rawValue,
            availableCommands: [
                .togglePlayPause,
                .skipBack,
                .skipForward,
                .setPlaybackRate,
                .beginInterjection,
                .finishInterjection,
                .generateInterjectionSummary
            ],
            durationMs: 120_000
        )

        XCTAssertEqual(
            Gate2LiveActivityPolicy.availableCommands(from: snapshot),
            [.beginInterjection, .finishInterjection]
        )
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
    private(set) var publishCallCount = 0
    private(set) var lastSharedMarginPrompt: Gate2SharedMarginActivityPrompt?
    private(set) var lastUpcomingSharedMargins: [Gate2LiveActivityNavigationEntry] = []

    func publish(
        _ snapshot: CompactControlSnapshot,
        sharedMarginPrompt: Gate2SharedMarginActivityPrompt?,
        upcomingSharedMargins: [Gate2LiveActivityNavigationEntry]
    ) {
        publishCallCount += 1
        lastSharedMarginPrompt = sharedMarginPrompt
        lastUpcomingSharedMargins = upcomingSharedMargins
    }

    func endAll() {
        endAllCallCount += 1
        status = "ended"
    }
}
