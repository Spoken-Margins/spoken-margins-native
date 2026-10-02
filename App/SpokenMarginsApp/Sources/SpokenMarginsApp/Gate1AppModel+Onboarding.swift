import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

enum OnboardingStep: String, CaseIterable, Identifiable, Hashable {
    case firstInterjection = "first_interjection"
    case reviewedTimeline = "reviewed_timeline"
    case exportedSession = "exported_session"
    case addedOwnSource = "added_own_source"
    case addedFromSafari = "added_from_safari"
    case addedFromFiles = "added_from_files"
    case addedPodcast = "added_podcast"

    var id: String { rawValue }

    static let core: [OnboardingStep] = [
        .firstInterjection,
        .reviewedTimeline,
        .exportedSession
    ]

    static let sourceExploration: [OnboardingStep] = [
        .addedOwnSource,
        .addedFromSafari,
        .addedFromFiles,
        .addedPodcast
    ]
}

enum GuidedOnboardingStage: String, Equatable {
    case inactive
    case practiceInterjection = "practice_interjection"
    case reviewTimeline = "review_timeline"
    case optionalAI = "optional_ai"
    case exportSession = "export_session"
    case complete
}

extension Gate1AppModel {
    static func loadOnboardingSteps() -> Set<OnboardingStep> {
        Set(
            (UserDefaults.standard.stringArray(forKey: onboardingStepsKey) ?? [])
                .compactMap(OnboardingStep.init(rawValue:))
        )
    }

    static func loadGuidedOnboardingStage() -> GuidedOnboardingStage {
        guard let rawValue = UserDefaults.standard.string(forKey: guidedOnboardingStageKey) else {
            return .inactive
        }
        return GuidedOnboardingStage(rawValue: rawValue) ?? .inactive
    }

    var onboardingCoreCompletedCount: Int {
        OnboardingStep.core.filter(completedOnboardingSteps.contains).count
    }

    var onboardingSourceCompletedCount: Int {
        OnboardingStep.sourceExploration.filter(completedOnboardingSteps.contains).count
    }

    var hasCompletedCoreOnboarding: Bool {
        onboardingCoreCompletedCount == OnboardingStep.core.count
    }

    var shouldShowOnboardingCard: Bool {
        !Self.isRunningUnitTests
            && !CommandLine.arguments.contains("--ui-testing")
            && !hasCompletedCoreOnboarding
            && !isOnboardingCardDismissed
    }

    var shouldShowGuidedOnboardingCoach: Bool {
        guidedOnboardingStage != .inactive
            && selectedItem.id == Self.guidedOnboardingItemId
    }

    func isOnboardingStepComplete(_ step: OnboardingStep) -> Bool {
        completedOnboardingSteps.contains(step)
    }

    func markOnboardingSteps(_ steps: Set<OnboardingStep>) {
        let updated = completedOnboardingSteps.union(steps)
        guard updated != completedOnboardingSteps else { return }
        completedOnboardingSteps = updated
        UserDefaults.standard.set(updated.map(\.rawValue).sorted(), forKey: Self.onboardingStepsKey)
    }

    func setGuidedOnboardingStage(_ stage: GuidedOnboardingStage) {
        guidedOnboardingStage = stage
        UserDefaults.standard.set(stage.rawValue, forKey: Self.guidedOnboardingStageKey)
    }

    func reconcileOnboardingEvidence(store: SQLiteSessionStore) throws {
        let items = try store.listItems()
        var evidence = OnboardingEvidenceClassifier.sourceSteps(items: items)
        let hasSavedInterjection = try store.loadSessions().contains { session in
            ((try? store.loadInterjections(sessionId: session.id)) ?? [])
                .contains(where: { $0.status == "active" })
        }
        if hasSavedInterjection {
            evidence.insert(.firstInterjection)
        }
        markOnboardingSteps(evidence)
    }

    func dismissOnboardingCard() {
        isOnboardingCardDismissed = true
        UserDefaults.standard.set(true, forKey: Self.onboardingCardDismissedKey)
    }

    func restoreOnboardingCard() {
        isOnboardingCardDismissed = false
        UserDefaults.standard.set(false, forKey: Self.onboardingCardDismissedKey)
    }

    func pauseGuidedOnboarding() {
        setGuidedOnboardingStage(.inactive)
    }

    func continueGuidedOnboardingPastAI() {
        guard guidedOnboardingStage == .optionalAI else { return }
        setGuidedOnboardingStage(.exportSession)
    }

    func openAISettingsFromOnboarding() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_ai_settings_from_onboarding") else { return }
        continueGuidedOnboardingPastAI()
        isHelpPresented = false
        screen = .settings
    }

    func finishGuidedOnboarding() {
        setGuidedOnboardingStage(.inactive)
    }

    func recordTimelineInterjectionViewed(interjectionId: String) {
        guard selectedItem.interjections.contains(where: { $0.id == interjectionId }) else { return }
        recordTimelineReviewCompleted()
    }

    func recordTimelineReviewCompleted() {
        markOnboardingSteps([.reviewedTimeline])
        if guidedOnboardingStage == .reviewTimeline {
            setGuidedOnboardingStage(.optionalAI)
        }
    }

    func recordSessionExported() {
        guard exportSessionId != nil else { return }
        markOnboardingSteps([.exportedSession])
        if guidedOnboardingStage == .exportSession {
            setGuidedOnboardingStage(.complete)
        }
    }

    func resetOnboardingProgressForTesting() {
        guard Self.isRunningUnitTests else { return }
        completedOnboardingSteps = []
        guidedOnboardingStage = .inactive
        isOnboardingCardDismissed = false
        UserDefaults.standard.removeObject(forKey: Self.onboardingStepsKey)
        UserDefaults.standard.removeObject(forKey: Self.guidedOnboardingStageKey)
        UserDefaults.standard.removeObject(forKey: Self.onboardingCardDismissedKey)
    }

    static func shouldSeedWelcomeSample(
        libraryIsEmpty: Bool,
        storedVersion: Int,
        isUITesting: Bool
    ) -> Bool {
        libraryIsEmpty && storedVersion < welcomeSampleSeedVersion && !isUITesting
    }

    static func makeBundledGuidedOnboardingItem() -> Item {
        Item(
            id: guidedOnboardingItemId,
            title: "Guided Tour: Add and Prepare Sources",
            mediaType: "guided_tour",
            text: """
            Welcome to Spoken Margins. Add text, PDF, a readable webpage, or a podcast from Add Source. You can also import a DRM-free EPUB or an MP3, M4A, M4B, or audio-bearing MP4 audiobook. Native text and EPUB chapters can be prepared for offline listening. Preparation progress, storage use, retry, and cancellation stay visible; changing playback speed does not regenerate prepared audio. Followed sources appear in New from Sources and never import until you choose an entry. Use the sleep timer for a timed pause or the end of the current chapter.
            """,
            externalReference: "bundled://guided-onboarding.v1",
            status: "ready",
            externalReferenceType: "guided_onboarding",
            sourceTitle: "Spoken Margins",
            createdAt: Date()
        )
    }

    static func makeBundledGuidedOnboardingMap() -> ListeningMap {
        let textLength = makeBundledGuidedOnboardingItem().text?.count ?? 0
        return ListeningMap(
            id: "map-guided-onboarding",
            itemId: guidedOnboardingItemId,
            overview: "Practice listening, interjecting, reviewing the timeline, and exporting a session.",
            chapters: [
                Chapter(
                    id: "guided-onboarding-core-loop",
                    title: "The Core Loop",
                    startChar: 0,
                    endChar: textLength,
                    percent: 0
                )
            ]
        )
    }

    func addSampleItem() {
        do {
            let store = try requireStore()
            let (item, map) = try makeAppOverviewSample()
            try store.saveItem(item)
            try store.saveListeningMap(map)
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            activeItemId = item.id
            try refreshLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: item.id, store: store)
            screen = .item
            reportSuccess("Sample added.")
        } catch {
            reportFailure(error, context: "Add sample failed")
        }
    }

    func startGuidedOnboarding() {
        do {
            let store = try requireStore()
            if !(try store.listItems()).contains(where: { $0.id == Self.guidedOnboardingItemId }) {
                try store.saveItem(Self.makeBundledGuidedOnboardingItem())
                try store.saveListeningMap(Self.makeBundledGuidedOnboardingMap())
                UserDefaults.standard.set(1, forKey: Self.guidedOnboardingSeedVersionKey)
                UserDefaults.standard.removeObject(forKey: Self.guidedOnboardingTombstoneKey)
                try refreshLibraryRows(store: store)
            } else if try store.loadListeningMap(itemId: Self.guidedOnboardingItemId) == nil {
                try store.saveListeningMap(Self.makeBundledGuidedOnboardingMap())
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            restoreOnboardingCard()
            isHelpPresented = false
            if hasCompletedCoreOnboarding {
                setGuidedOnboardingStage(.practiceInterjection)
            } else if !isOnboardingStepComplete(.firstInterjection) {
                setGuidedOnboardingStage(.practiceInterjection)
            } else if !isOnboardingStepComplete(.reviewedTimeline) {
                setGuidedOnboardingStage(.reviewTimeline)
            } else if !isOnboardingStepComplete(.exportedSession) {
                setGuidedOnboardingStage(.optionalAI)
            } else {
                setGuidedOnboardingStage(.complete)
            }
            startItem(id: Self.guidedOnboardingItemId)
        } catch {
            reportFailure(error, context: "Guided tour setup failed")
        }
    }

    func makeAppOverviewSample() throws -> (Item, ListeningMap) {
        let itemId = Self.welcomeSampleItemId
        let optionalAIOverview = remoteProviderExperienceEnabled
            ? "Summarize Notes synthesizes the Margins in this session. Discuss answers a question using relevant source and session context. Both are optional and require your OpenAI API key, network access, and separate permission to send content."
            : "Summarize Notes synthesizes the Margins in this session with Apple’s on-device model when available. Remote discussion and third-party API keys are disabled; you can copy your notes to another chatbot and paste its response back into Spoken Margins."
        let markdown = """
        # Welcome to Spoken Margins

        Spoken Margins is a structured listening workspace. It restores the headings, progress, margin notes, and easy navigation that ordinary audio loses, so reading can become an active listening session.

        ## Start with the Listening Map

        Tap Start Listening on this source. The overview plays first, and the Timeline shows the chapters below. Tap any chapter to jump directly to it while keeping your place in the source.

        ## Move forward and backward

        On Now Playing, use the backward and forward buttons around Play to move by paragraph. The progress slider can move farther through the source. Open More to change the speech rate.

        ## Interject while you listen

        This is your practice cue. Tap Add a Margin, say one thing you want to remember about this tour, then save. Spoken Margins anchors your thought near the passage you were hearing and resumes without losing your place. Prefer typing? Tap the writing button beside Record. Open Margins to find, star, and review your note, or choose Play this moment to hear its source again.

        ## Load your own sources

        Return to Library and tap Add. Choose Paste Text or Link or Podcast, then Add to Library. You can also choose a document, PDF, DRM-free EPUB, or an MP3, M4A, M4B, or audio-bearing MP4 audiobook. Adding a source keeps your current listening session in place; choose the new item when you are ready to listen. In Safari, enable Spoken Margins Text under Manage Extensions to capture selected text or a readable article, or run the Add Article to Spoken Margins Shortcut from Safari’s Share menu. You can also share a PDF, Markdown file, or text file directly to Spoken Margins.

        ## Keep what matters

        \(optionalAIOverview) Listening, interjections, the Timeline, and export work without AI. Export the useful context for another writing or thinking tool. The goal is not passive playback; it is to help you retain and develop the ideas that mattered.
        """
        let parsed = try ObsidianMarkdownParser.parse(
            fileName: "Welcome to Spoken Margins.md",
            contents: markdown
        )
        let item = Item(
            id: itemId,
            title: parsed.title,
            mediaType: "text",
            text: parsed.text,
            externalReference: "",
            status: "ready"
        )
        guard var map = parsed.deterministicListeningMap(itemId: itemId) else {
            throw SessionKitError.persistenceFailed("welcome_sample_listening_map_missing")
        }
        map.overview = "Take a guided tour of the Listening Map, playback navigation, spoken Margins, and the three ways to add your own sources."
        return (item, map)
    }

    func dismissLegacyLibraryResetNotice() {
        legacyLibraryResetNotice = nil
    }

    func seedUITestingGeneratedTimelineIfNeeded(sessionId: String, engine: SessionEngine, store: SQLiteSessionStore) throws {
        guard CommandLine.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] == nil,
              try store.loadTurns(sessionId: sessionId).isEmpty else {
            return
        }
        _ = try engine.submitFollowup(text: "Can you respond to my interjection?")
        _ = try engine.aiStreamDelta(
            turnId: "turn-response-001",
            content: """
            <sm_summary>Here is a quick response to your interjection.</sm_summary>
            <sm_response>Here is a quick response to your interjection. First, your test is checking whether generated turns stay easy to navigate. Second, the response chapters should remain tappable in the main timeline.</sm_response>
            <sm_chapters_json>{"schemaVersion":"assistant-response-map.v1","chapters":[{"id":"ai-ch-1","title":"Quick Response","anchor":"Here is a quick response"},{"id":"ai-ch-2","title":"Timeline Navigation","anchor":"Second, the response chapters"}]}</sm_chapters_json>
            """
        )
        _ = try engine.aiJobCompleted(turnId: "turn-response-001")
        snapshot = try engine.inspectSession(sessionId: sessionId)
    }

    func seedUITestingSummaryInterjectionIfNeeded(
        sessionId: String,
        engine: SessionEngine,
        store: SQLiteSessionStore
    ) throws {
        guard CommandLine.arguments.contains("--ui-testing"),
              let note = ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_INTERJECTION"],
              try store.loadInterjections(sessionId: sessionId).isEmpty else { return }
        let interjection = Interjection(
            id: "ij-ui-summary",
            itemId: activeItemId,
            sessionId: sessionId,
            targetType: .item,
            targetId: activeItemId,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: snapshot.sourceProgressPercent,
            anchor: Anchor(
                anchorType: .text,
                startChar: 0,
                endChar: min(24, selectedItem.text.count),
                anchorBefore: String(selectedItem.text.prefix(120)),
                anchorAfter: ""
            ),
            audioPath: nil,
            audioStatus: "saved",
            transcriptionStatus: "transcribed",
            transcript: note,
            cleanedTranscript: nil,
            displayText: note,
            status: "active",
            anchorContextStatus: .ready
        )
        try store.saveInterjection(interjection)
        snapshot = try engine.inspectSession(sessionId: sessionId)
        diagnostics["uiTestSummaryFixture"] = interjection.id
    }

    func refreshGuidedOnboardingContent() async {
        guard !UserDefaults.standard.bool(forKey: Self.guidedOnboardingTombstoneKey),
              let coordinator = guidedOnboardingCoordinator,
              let store else { return }
        do {
            let payload = try await coordinator.refresh()
            let priorChecksum = UserDefaults.standard.string(forKey: "guidedOnboardingAudioChecksum")
            var item = (try? store.loadItem(id: Self.guidedOnboardingItemId)) ?? Self.makeBundledGuidedOnboardingItem()
            item.title = payload.manifest.title
            item.sourceTitle = "Spoken Margins"
            item.media = ItemMedia(
                sourceType: .nativeMediaFile,
                url: payload.audioURL.absoluteString,
                nativeMediaId: "guided-onboarding-audio"
            )
            try store.saveItem(item)
            try store.saveAudioAsset(AudioAsset(
                id: "guided-onboarding-audio",
                itemId: item.id,
                audioSourceType: .nativeMediaFile,
                availability: .localPhone,
                url: payload.audioURL.absoluteString,
                title: payload.manifest.title
            ))
            try store.saveTranscriptTimeline(SourceTranscriptTimeline(
                id: "timeline-guided-onboarding",
                itemId: item.id,
                createdAt: Date(),
                timeline: TranscriptTimeline(
                    segments: [],
                    chapters: [
                        MediaTimelineChapter(
                            id: "guided-onboarding-core-loop",
                            title: "The Core Loop",
                            startMs: 0,
                            transcriptSegmentId: "guided-onboarding-core-loop"
                        )
                    ]
                )
            ))
            UserDefaults.standard.set(payload.manifest.audioChecksumSHA256, forKey: "guidedOnboardingAudioChecksum")
            if payload.audioChanged, priorChecksum != nil, snapshot.itemId == item.id {
                _ = try? engine?.stopPlayback()
                snapshot = SessionSnapshot()
                diagnostics["guidedOnboardingProgress"] = "reset_for_audio_change"
            }
            try refreshLibraryRows(store: store)
            diagnostics["guidedOnboardingRemote"] = "ready:v\(payload.manifest.contentVersion)"
        } catch {
            diagnostics["guidedOnboardingRemote"] = "fallback:\(String(describing: type(of: error)))"
        }
    }

    func loadFixtureItem(name: String) throws -> Item {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "fixtures/items") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.item(at: url)
    }

    func loadFixtureMap(name: String) throws -> ListeningMap {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "fixtures/maps") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.listeningMap(at: url)
    }

    #if SPOKEN_MARGINS_WATCH
    func seedGate4WatchPackageFixture(store: SQLiteSessionStore) throws {
        guard let url = Bundle.main.url(forResource: "offline-package", withExtension: "json", subdirectory: "fixtures/watch") else {
            return
        }
        let package = try ContractFixtureLoader.watchAudioPackage(at: url)
        try store.saveWatchAudioPackage(package)
    }
    #endif
}
