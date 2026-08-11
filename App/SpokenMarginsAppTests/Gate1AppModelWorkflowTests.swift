import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class Gate1AppModelWorkflowTests: XCTestCase {
    func testPlaybackHeaderKeepsTheItemTitleUnprefixedWhenItIsNotAChapter() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.selectedItem = ItemDetailState(title: "Why Apple Is Heading Into a Pivotal Moment")
        model.snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
        model.snapshot.chapterTitle = "Why Apple Is Heading Into a Pivotal Moment"

        XCTAssertEqual(model.playbackHeaderTitle, "Why Apple Is Heading Into a Pivotal Moment")
    }

    func testPlaybackHeaderPrefixesARealChapterWithItsNumber() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.selectedItem = ItemDetailState(
            id: "item-1",
            title: "A Long Article",
            chapters: [
                Chapter(id: "chapter-1", title: "Opening", startChar: 0, endChar: 100, percent: 0),
                Chapter(id: "chapter-2", title: "The Pivot", startChar: 100, endChar: 200, percent: 50)
            ]
        )
        model.snapshot.targetType = TargetType.itemTextTTS.rawValue
        model.snapshot.chapterTitle = "The Pivot"

        XCTAssertEqual(model.playbackHeaderTitle, "Ch. 2: The Pivot")
    }

    func testPlaybackHeaderNumbersARealPodcastChapter() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.selectedItem = ItemDetailState(
            id: "episode-1",
            title: "A Podcast Episode",
            mediaChapters: [
                MediaTimelineChapter(id: "intro", title: "Introduction", startMs: 0, transcriptSegmentId: "segment-1"),
                MediaTimelineChapter(id: "analysis", title: "The Analysis", startMs: 60_000, transcriptSegmentId: "segment-2")
            ]
        )
        model.snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
        model.snapshot.chapterTitle = "The Analysis"

        XCTAssertEqual(model.playbackHeaderTitle, "Ch. 2: The Analysis")
    }

    func testNativeAudioExportDisablesFullSourceTextOption() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.selectedItem = ItemDetailState(id: "podcast", title: "Podcast", isNativeAudio: true)
        XCTAssertFalse(model.exportSourceTextAvailable)

        model.selectedItem = ItemDetailState(id: "article", title: "Article", isNativeAudio: false)
        XCTAssertTrue(model.exportSourceTextAvailable)
    }

    func testDeletedInterjectionsAreNeverEligibleForAnotherSummary() {
        let active = Interjection(
            id: "active",
            itemId: "item",
            sessionId: "session",
            targetType: .item,
            targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "Keep me",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )
        var deleted = active
        deleted.id = "deleted"
        deleted.status = "deleted"

        let eligible = Gate1SummaryEligibility.unsummarizedInterjections(
            turns: [],
            interjections: [active, deleted],
            currentTargetType: TargetType.itemTextTTS.rawValue,
            currentTargetId: "item"
        )

        XCTAssertEqual(eligible.map(\.id), ["active"])
    }

    func testTimelineMarksTheCurrentSourceChapter() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let opening = Chapter(id: "chapter-1", title: "Opening", startChar: 0, endChar: 100, percent: 0)
        let pivot = Chapter(id: "chapter-2", title: "The Pivot", startChar: 100, endChar: 200, percent: 50)
        model.selectedItem = ItemDetailState(id: "item-1", title: "A Long Article", chapters: [opening, pivot])
        model.snapshot.targetType = TargetType.itemTextTTS.rawValue
        model.snapshot.chapterTitle = pivot.title

        XCTAssertFalse(model.isCurrentTimelineChapter(opening))
        XCTAssertTrue(model.isCurrentTimelineChapter(pivot))
    }

    func testTimelineDoesNotMarkASourceChapterDuringAssistantPlayback() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let opening = Chapter(id: "chapter-1", title: "Opening", startChar: 0, endChar: 100, percent: 0)
        model.selectedItem = ItemDetailState(id: "item-1", title: "A Long Article", chapters: [opening])
        model.snapshot.targetType = TargetType.assistantTurnTTS.rawValue
        model.snapshot.chapterTitle = opening.title

        XCTAssertFalse(model.isCurrentTimelineChapter(opening))
    }

    func testConfiguredProviderKeyIgnoresWhitespaceOnlyValues() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.providerAPIKey = "   \n"
        XCTAssertFalse(model.hasConfiguredProviderAPIKey)

        model.providerAPIKey = "configured-key"
        XCTAssertTrue(model.hasConfiguredProviderAPIKey)
    }

    func testWelcomeSampleSeedsOnlyForANewEmptyNonUITestLibrary() {
        XCTAssertTrue(Gate1AppModel.shouldSeedWelcomeSample(
            libraryIsEmpty: true,
            storedVersion: 0,
            isUITesting: false
        ))
        XCTAssertFalse(Gate1AppModel.shouldSeedWelcomeSample(
            libraryIsEmpty: false,
            storedVersion: 0,
            isUITesting: false
        ))
        XCTAssertTrue(Gate1AppModel.shouldSeedWelcomeSample(
            libraryIsEmpty: true,
            storedVersion: 1,
            isUITesting: false
        ))
        XCTAssertFalse(Gate1AppModel.shouldSeedWelcomeSample(
            libraryIsEmpty: true,
            storedVersion: 2,
            isUITesting: false
        ))
        XCTAssertFalse(Gate1AppModel.shouldSeedWelcomeSample(
            libraryIsEmpty: true,
            storedVersion: 0,
            isUITesting: true
        ))
    }

    func testBundledSampleExplainsTheAppInsteadOfSeedingTheContractArticle() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        model.addSampleItem()

        XCTAssertEqual(model.selectedItem.title, "Welcome to Spoken Margins")
        XCTAssertTrue(model.selectedItem.text.contains("structured listening workspace"))
        XCTAssertTrue(model.selectedItem.text.contains("Listening Map"))
        XCTAssertTrue(model.selectedItem.text.contains("Tap Interject"))
        XCTAssertTrue(model.selectedItem.text.contains("backward and forward buttons"))
        XCTAssertTrue(model.selectedItem.text.contains("paste a podcast"))
        XCTAssertTrue(model.selectedItem.text.contains("Import Text or PDF Files"))
        XCTAssertTrue(model.selectedItem.text.contains("Summarize Notes synthesizes"))
        XCTAssertTrue(model.selectedItem.text.contains("enable Spoken Margins Text"))
        XCTAssertFalse(model.selectedItem.text.contains("You Can't Inspect the Pill"))
        XCTAssertEqual(model.selectedItem.chapters.count, 5)
    }

    func testGuidedOnboardingAdvancesOnlyFromCompletedProductActions() throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            interjectionTranscriptionHandler: { _ in "A practice note." }
        )
        model.resetOnboardingProgressForTesting()
        defer { model.resetOnboardingProgressForTesting() }
        model.resetAndSeed()

        model.startGuidedOnboarding()

        XCTAssertEqual(model.selectedItem.id, Gate1AppModel.welcomeSampleItemId)
        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.guidedOnboardingStage, .practiceInterjection)
        XCTAssertFalse(model.isOnboardingStepComplete(.firstInterjection))

        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.snapshot.isRecording)
        model.dispatchGate2CompactCommand(.finishInterjection)

        XCTAssertTrue(model.isOnboardingStepComplete(.firstInterjection))
        XCTAssertEqual(model.guidedOnboardingStage, .reviewTimeline)
        let interjection = try XCTUnwrap(model.selectedItem.interjections.first)

        model.recordTimelineInterjectionViewed(interjectionId: interjection.id)

        XCTAssertTrue(model.isOnboardingStepComplete(.reviewedTimeline))
        XCTAssertEqual(model.guidedOnboardingStage, .optionalAI)

        model.continueGuidedOnboardingPastAI()
        XCTAssertEqual(model.guidedOnboardingStage, .exportSession)
        model.openExport()
        model.recordSessionExported()

        XCTAssertTrue(model.isOnboardingStepComplete(.exportedSession))
        XCTAssertTrue(model.hasCompletedCoreOnboarding)
        XCTAssertEqual(model.guidedOnboardingStage, .complete)
    }

    func testGuidedOnboardingTimelineChapterCompletesReviewStep() throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient()
        )
        model.resetOnboardingProgressForTesting()
        defer { model.resetOnboardingProgressForTesting() }
        model.resetAndSeed()
        model.startGuidedOnboarding()
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        let chapter = try XCTUnwrap(model.selectedItem.chapters.first)

        model.jumpToChapter(chapter)

        XCTAssertEqual(model.guidedOnboardingStage, .reviewTimeline)
        XCTAssertFalse(model.isOnboardingStepComplete(.reviewedTimeline))

        model.jumpToChapter(chapter, fromTimeline: true)

        XCTAssertTrue(model.isOnboardingStepComplete(.reviewedTimeline))
        XCTAssertEqual(model.guidedOnboardingStage, .optionalAI)
    }

    func testManualImportCountsAsOwnSourceButNotAsSafariFileOrPodcast() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetOnboardingProgressForTesting()
        defer { model.resetOnboardingProgressForTesting() }
        model.resetAndSeed()
        model.importTitle = "My Source"
        model.importText = "This source belongs to the user."

        model.importTextItem()

        XCTAssertTrue(model.isOnboardingStepComplete(.addedOwnSource))
        XCTAssertFalse(model.isOnboardingStepComplete(.addedFromSafari))
        XCTAssertFalse(model.isOnboardingStepComplete(.addedFromFiles))
        XCTAssertFalse(model.isOnboardingStepComplete(.addedPodcast))
    }

    func testManualImportClearsEntryFieldsAfterSuccessfulCreate() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Scratch Item"
        model.importText = "This is pasted text. It should not remain in the import form."

        model.importTextItem()

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.importTitle, "")
        XCTAssertEqual(model.importText, "")
        XCTAssertEqual(model.selectedItem.title, "Scratch Item")
    }

    func testManualImportBuildsListeningMapFromPastedMarkdownHeadings() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Structured Notes"
        model.importText = """
        # Source Heading

        Opening context.

        ## First Claim

        Evidence for the first claim.

        ## Counterpoint

        Evidence for the counterpoint.

        ## Conclusion

        Closing synthesis.
        """

        model.importTextItem()

        XCTAssertEqual(model.selectedItem.title, "Structured Notes")
        XCTAssertEqual(model.selectedItem.chapters.map(\.title), ["Source Heading", "First Claim", "Counterpoint", "Conclusion"])
        XCTAssertEqual(model.selectedItem.chapters.first?.startChar, 0)
        XCTAssertEqual(model.selectedItem.chapters.last?.endChar, model.selectedItem.text.count)
        XCTAssertTrue(zip(model.selectedItem.chapters, model.selectedItem.chapters.dropFirst()).allSatisfy {
            $0.endChar == $1.startChar
        })
    }

    func testManualImportDoesNotInventChaptersForUnstructuredText() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Plain Notes"
        model.importText = "A paragraph without structural headings. Another sentence follows."

        model.importTextItem()

        XCTAssertEqual(model.selectedItem.title, "Plain Notes")
        XCTAssertTrue(model.selectedItem.chapters.isEmpty)
    }

    func testRapidManualImportsReceiveDistinctIdentifiers() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "First Import"
        model.importText = "The first rapidly imported item."
        model.importTextItem()
        let firstID = model.selectedItem.id

        model.importTitle = "Second Import"
        model.importText = "The second rapidly imported item."
        model.importTextItem()
        let secondID = model.selectedItem.id

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertTrue(model.libraryItems.contains(where: { $0.id == firstID }))
        XCTAssertTrue(model.libraryItems.contains(where: { $0.id == secondID }))
    }

    func testLeavingPlaybackKeepsSessionPlayingAndShowsMiniPlayer() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Currently Playing"
        model.importText = "This remains the Now Playing item."
        model.importTextItem()
        let playingItemId = model.selectedItem.id

        model.openHome()
        model.openItem(id: "item-pill")
        model.openHome()

        XCTAssertEqual(model.screen, .home)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertTrue(model.shouldShowMiniPlayer)
        model.openPlayback()
        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.selectedItem.id, playingItemId)
        XCTAssertFalse(model.shouldShowMiniPlayer)
    }

    func testRoutinePlaybackAndNavigationActionsDoNotPresentFeedback() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        XCTAssertNil(model.feedbackEvent)

        model.startItem(id: "item-pill")
        XCTAssertNil(model.feedbackEvent)
        XCTAssertTrue(model.statusMessage.hasPrefix("Started "))

        model.pause()
        XCTAssertNil(model.feedbackEvent)
        XCTAssertEqual(model.statusMessage, "Paused.")

        model.resumePlayback()
        XCTAssertNil(model.feedbackEvent)
        XCTAssertEqual(model.statusMessage, "Resumed.")

        model.openHome()
        model.openItem(id: "item-pill")
        XCTAssertNil(model.feedbackEvent)
        XCTAssertTrue(model.statusMessage.hasPrefix("Opened "))
    }

    func testBuildingVisibleExportPreviewDoesNotPresentFeedback() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        model.openExport()
        model.buildExport()

        XCTAssertFalse(model.exportPreview.isEmpty)
        XCTAssertNil(model.feedbackEvent)
        XCTAssertEqual(model.statusMessage, "Built session export.")
    }

    func testPlaybackHeaderOpensCurrentItemWithoutStoppingItsSession() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)

        model.openCurrentPlaybackItem()

        XCTAssertEqual(model.screen, .item)
        XCTAssertEqual(model.selectedItem.id, "item-pill")
        XCTAssertTrue(model.selectedItem.sessions.contains(where: { $0.id == sessionID }))
        XCTAssertEqual(model.snapshot.sessionId, sessionID)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertTrue(model.shouldShowMiniPlayer)
    }

    func testChapterFromAnotherItemClosesRestoredSessionAndStartsSelectedItem() throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let previousSessionID = try XCTUnwrap(model.snapshot.sessionId)

        model.addSampleItem()
        let selectedItemID = model.selectedItem.id
        let chapter = try XCTUnwrap(model.selectedItem.chapters.dropFirst().first)
        model.jumpToChapter(chapter)

        XCTAssertEqual(model.snapshot.itemId, selectedItemID)
        XCTAssertNotEqual(model.snapshot.sessionId, previousSessionID)
        XCTAssertEqual(model.snapshot.chapterTitle, chapter.title)
        XCTAssertEqual(model.screen, .playback)
        model.openItem(id: "item-pill")
        XCTAssertTrue(model.selectedItem.sessions.contains { $0.id == previousSessionID })
    }

    func testLargeExportUsesBoundedVisiblePreviewWithoutChangingCopiedPayload() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let complete = String(repeating: "source context ", count: 4_000)
        model.exportPreview = complete

        XCTAssertTrue(model.exportPreviewIsTruncated)
        XCTAssertTrue(model.displayedExportPreview.contains("Preview truncated"))
        XCTAssertLessThan(model.displayedExportPreview.count, model.exportPreview.count)
        XCTAssertEqual(model.exportPreview, complete)
        XCTAssertFalse(model.exportPreviewSizeDescription.isEmpty)
    }

    func testTrashUndoPreservesItemSessions() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        XCTAssertFalse(model.selectedItem.sessions.isEmpty)

        model.moveItemToTrash(id: "item-pill")

        XCTAssertFalse(model.libraryItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertTrue(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertEqual(model.trashUndo?.itemId, "item-pill")
        XCTAssertNil(model.feedbackEvent)

        model.undoLastTrash()
        model.openItem(id: "item-pill")

        XCTAssertTrue(model.libraryItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertFalse(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertFalse(model.selectedItem.sessions.isEmpty, "Restoring an item should restore its existing sessions")
    }

    func testTrashUndoAutoDismissesAfterConfiguredDelay() async throws {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            trashUndoDismissDelay: .milliseconds(20)
        )
        model.resetAndSeed()

        model.moveItemToTrash(id: "item-pill")

        XCTAssertEqual(model.trashUndo?.itemId, "item-pill")
        try await waitFor("trash Undo to auto-dismiss") {
            model.trashUndo == nil
        }
        XCTAssertTrue(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
    }

    func testReplacingTrashUndoCancelsOlderDismissal() async throws {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            trashUndoDismissDelay: .milliseconds(80)
        )
        model.resetAndSeed()
        model.importTitle = "Second Item"
        model.importText = "A second item to delete."
        model.importTextItem()
        let secondItemId = model.selectedItem.id

        model.moveItemToTrash(id: "item-pill")
        let firstUndoId = try XCTUnwrap(model.trashUndo?.id)
        try await Task.sleep(for: .milliseconds(40))
        model.moveItemToTrash(id: secondItemId)
        let secondUndoId = try XCTUnwrap(model.trashUndo?.id)

        XCTAssertNotEqual(firstUndoId, secondUndoId)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.trashUndo?.id, secondUndoId, "The older timer must not dismiss the replacement Undo")
        try await waitFor("replacement trash Undo to auto-dismiss") {
            model.trashUndo == nil
        }
    }

    func testPermanentDeletionCannotCrossFireIntoRestore() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.moveItemToTrash(id: "item-pill")

        model.permanentlyDeleteItem(id: "item-pill")

        XCTAssertFalse(model.libraryItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertFalse(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
        model.restoreItem(id: "item-pill")
        XCTAssertFalse(model.libraryItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertFalse(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
    }

    func testEmptyRecentlyDeletedPermanentlyDeletesEveryTrashedItem() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.importTitle = "Second Trashed Item"
        model.importText = "A second item with its own listening session."
        model.importTextItem()
        let secondID = model.selectedItem.id

        model.moveItemToTrash(id: "item-pill")
        model.moveItemToTrash(id: secondID)
        XCTAssertEqual(Set(model.recentlyDeletedItems.map(\.id)), ["item-pill", secondID])

        model.permanentlyDeleteRecentlyDeletedItems()

        XCTAssertTrue(model.recentlyDeletedItems.isEmpty)
        XCTAssertFalse(model.libraryItems.contains(where: { $0.id == "item-pill" || $0.id == secondID }))
        XCTAssertNil(model.trashUndo)
    }

    func testStoppingTextPlaybackKeepsSessionInProgressAndResumable() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let sessionId = model.snapshot.sessionId

        model.endSession()

        XCTAssertNil(model.snapshot.sessionId)
        XCTAssertEqual(model.snapshot.phase, .idle)
        XCTAssertEqual(model.snapshot.status, .idle)
        XCTAssertFalse(model.shouldShowMiniPlayer)
        XCTAssertEqual(model.feedbackEvent?.kind, .success)
        XCTAssertEqual(model.feedbackEvent?.message, "Session saved. You can resume it later.")
        let saved = model.selectedItem.sessions.first(where: { $0.id == sessionId })
        XCTAssertEqual(saved?.status, "in_progress")
        XCTAssertLessThan(saved?.completionPercent ?? 100, 100)
        model.dismissFeedback()
        if let saved {
            model.resumeSession(saved)
        }
        XCTAssertEqual(model.snapshot.sessionId, sessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertNil(model.feedbackEvent)
    }

    func testHomePlayResumesLatestSessionWithoutCreatingAnother() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)
        let countBefore = model.selectedItem.sessions.count

        model.openHome()
        model.startItem(id: "item-pill")

        XCTAssertEqual(model.snapshot.sessionId, sessionID)
        XCTAssertEqual(model.selectedItem.sessions.count, countBefore)
        XCTAssertEqual(model.snapshot.status, .playing)
    }

    func testHomeRefreshesAndOpensNewestSessionAtOneHundredPercent() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let olderSessionID = try XCTUnwrap(model.snapshot.sessionId)

        model.startNewSession(id: "item-pill")
        let completedSessionID = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertNotEqual(completedSessionID, olderSessionID)

        // Starting a new session first persists the older session immediately.
        // Wait before updating the new session so their whole-second persisted
        // timestamps exercise newest-session ordering without a UUID tie-break.
        try await Task.sleep(for: .seconds(1.1))
        model.skipUnit = "section"
        model.skipForward()
        XCTAssertEqual(model.snapshot.sourceProgressPercent, 100)
        model.openHome()

        let row = try XCTUnwrap(model.libraryItems.first(where: { $0.id == "item-pill" }))
        XCTAssertTrue(row.hasContinuationSession)
        XCTAssertEqual(row.continuationProgressPercent, 100)

        let sessionCount = model.selectedItem.sessions.count
        model.startItem(id: "item-pill")

        XCTAssertEqual(model.snapshot.sessionId, completedSessionID)
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.snapshot.sourceProgressPercent, 100)
        XCTAssertEqual(model.selectedItem.sessions.count, sessionCount)
    }

    func testFinishedSessionAtOneHundredPercentIsPreferredOverOlderInProgressSession() throws {
        let decoder = JSONDecoder()
        let older = try decoder.decode(Session.self, from: Data("""
        {"id":"older","itemId":"item-pill","status":"in_progress","phase":"item_playback","currentTargetType":"item_text_tts","currentTargetId":"item-pill","position":{"charOffset":0},"completionPercent":0,"playbackRate":1}
        """.utf8))
        let completed = try decoder.decode(Session.self, from: Data("""
        {"id":"completed","itemId":"item-pill","status":"finished","phase":"finished","currentTargetType":"item_text_tts","currentTargetId":"item-pill","position":{"charOffset":100},"completionPercent":100,"playbackRate":1}
        """.utf8))

        XCTAssertEqual(Gate1AppModel.preferredContinuationSession(in: [completed, older])?.id, completed.id)
    }

    func testExplicitStartNewSessionCreatesOneAdditionalSession() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let firstSessionID = try XCTUnwrap(model.snapshot.sessionId)

        model.startNewSession(id: "item-pill")

        XCTAssertNotEqual(model.snapshot.sessionId, firstSessionID)
        XCTAssertEqual(model.selectedItem.sessions.count, 2)
    }

    func testMissingAPIKeySummaryPreflightDoesNotMutateSession() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: true)
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        model.providerAPIKey = ""
        let snapshotBefore = model.snapshot
        let turnsBefore = model.selectedItem.turns

        model.summarize()

        XCTAssertTrue(model.isAISetupNeededPresented)
        XCTAssertEqual(model.snapshot, snapshotBefore)
        XCTAssertEqual(model.selectedItem.turns, turnsBefore)
        XCTAssertEqual(model.diagnostics["summaryPreflight"], "api_key_missing")
    }

    func testReleaseFeatureFlagDisablesRemoteProviderAndProbe() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
            localFoundationModelClient: WorkflowFoundationModelStub(availability: .unavailable("Unsupported test device"))
        )
        model.providerAPIKey = "configured-but-unused"

        model.probeProvider()

        XCTAssertFalse(model.remoteProviderExperienceEnabled)
        XCTAssertFalse(model.aiSummaryExperienceAvailable)
        XCTAssertEqual(model.providerProbeStatus, "Disabled by release feature flag")
        XCTAssertEqual(model.lastError, "Remote provider access is disabled in this release.")
    }

    func testUnavailableLocalModelDoesNotCreateRemoteSummaryOrDiscussionJobs() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
            localFoundationModelClient: WorkflowFoundationModelStub(availability: .unavailable("Unsupported test device"))
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        let snapshotBefore = model.snapshot
        let turnsBefore = model.selectedItem.turns

        model.summarize()
        model.discuss(followUp: "Send this remotely")

        XCTAssertEqual(model.snapshot, snapshotBefore)
        XCTAssertEqual(model.selectedItem.turns, turnsBefore)
        XCTAssertEqual(model.diagnostics["summaryPreflight"], "local_model_unavailable")
        XCTAssertEqual(model.lastError, "Discuss is disabled in this release. Copy your notes to another chatbot and paste its response back here instead.")
    }

    func testAvailableLocalFoundationModelCompletesInterjectionSummaryWithoutAPIKey() async throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            interjectionTranscriptionHandler: { _ in "Structure helps me remember the source." },
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
            localFoundationModelClient: WorkflowFoundationModelStub(
                availability: .available,
                summary: "The listener wants to preserve the relationship between structure and recall."
            )
        )
        model.providerAPIKey = ""
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        XCTAssertEqual(model.selectedItem.interjections.count, 1)
        XCTAssertTrue(model.canSummarizeInterjections)

        model.summarize()

        try await waitFor("local summary completion") {
            model.diagnostics["lastSummaryMode"] == "apple_foundation_on_device"
        }
        XCTAssertEqual(model.providerAPIKey, "")
        XCTAssertTrue(model.selectedItem.turns.contains {
            $0.turnType == "interjection_summary"
                && $0.text?.contains("relationship between structure and recall") == true
        })
    }

    func testFailedLocalSummaryExitsBusyStateAndCanBeRetried() async throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            interjectionTranscriptionHandler: { _ in "I am uncertain whether this premise supports the conclusion." },
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
            localFoundationModelClient: ThrowingWorkflowFoundationModelStub()
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        try await waitFor("listener note transcription") {
            model.selectedItem.interjections.first?.transcriptionStatus == "transcribed"
        }

        model.summarize()

        try await waitFor("local summary failure") {
            model.diagnostics["lastSummaryMode"] == "apple_foundation_failed"
        }
        XCTAssertFalse(model.isSummarizingInterjections)
        XCTAssertTrue(model.canSummarizeInterjections)
        XCTAssertTrue(model.canRetryLocalSummary)
        XCTAssertEqual(model.summaryActionTitle, "Retry Summary")
        XCTAssertEqual(model.selectedItem.turns.last(where: { $0.turnType == "interjection_summary" })?.status, "failed")
        XCTAssertEqual(model.feedbackEvent?.kind, .error)
        XCTAssertTrue(model.lastError?.contains("No cleaned-transcript fallback was saved") == true)
        XCTAssertTrue(model.lastError?.contains("Tap Retry Summary") == true)
    }

    func testCompletedSummaryPlaybackDoesNotBlockSummarizingANewInterjection() async throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            interjectionTranscriptionHandler: { _ in "A newly added listener note." },
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
            localFoundationModelClient: WorkflowFoundationModelStub(
                availability: .available,
                summary: "A concise listener note."
            )
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        model.summarize()
        try await waitFor("first local summary completion") {
            model.selectedItem.turns.filter { $0.turnType == "interjection_summary" && $0.status == "complete" }.count == 1
        }

        XCTAssertFalse(model.isSummarizingInterjections)
        XCTAssertFalse(model.canSummarizeInterjections)

        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)

        XCTAssertTrue(model.canSummarizeInterjections)
        XCTAssertFalse(model.isSummarizingInterjections)

        model.summarize()
        try await waitFor("second local summary completion") {
            model.selectedItem.turns.contains {
                $0.turnType == "interjection_summary"
                    && $0.status == "complete"
                    && $0.sourceInterjectionIds.count == 2
            }
        }
        XCTAssertFalse(model.isSummarizingInterjections)

        model.snapshot.targetType = TargetType.summaryTurnTTS.rawValue
        XCTAssertFalse(model.isSummarizingInterjections)
    }

    func testDefaultReleaseBuildsDeterministicTextMapOnPasteInsteadOfUsingFoundationModel() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
            localFoundationModelClient: WorkflowFoundationModelStub(availability: .available)
        )
        model.resetAndSeed()
        model.importTitle = "Deterministic Map Source"
        model.importText = "# Opening\n\nA first section.\n\n## Next Topic\n\nA second section."
        model.importTextItem()

        XCTAssertEqual(model.diagnostics["lastListeningMapMode"], "deterministic_headings")
        XCTAssertFalse(model.selectedItem.chapters.isEmpty)
        XCTAssertFalse(model.isGeneratingListeningMap)
    }

    func testBootstrapRestoresNewestUnfinishedSessionPausedWithoutAutoplay() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-relaunch-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
            }
        }
        let firstModel = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        firstModel.resetAndSeed()
        firstModel.startItem(id: "item-pill")
        firstModel.pause()
        let sessionID = try XCTUnwrap(firstModel.snapshot.sessionId)

        let relaunchedModel = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        relaunchedModel.bootstrapLibraryIfNeeded()

        XCTAssertEqual(relaunchedModel.snapshot.sessionId, sessionID)
        XCTAssertEqual(relaunchedModel.snapshot.status, .paused)
        XCTAssertTrue(relaunchedModel.shouldShowMiniPlayer)
        XCTAssertEqual(relaunchedModel.diagnostics["restoredSessionMode"], "paused_without_autoplay")
    }

    func testTextImportStartsLiveSpeechWhenPreparedRenderingIsUnavailable() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            forcePreparedTextGate: true
        )
        model.resetAndSeed()
        model.importTitle = "Prepared First"
        model.importText = "This text should start immediately while generated audio renders in the background."

        model.importTextItem()

        XCTAssertEqual(model.screen, .playback)
        XCTAssertNil(model.pendingPreparedTextStartItemId)
        XCTAssertNotNil(model.snapshot.sessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(model.preparedTextAudioStatus, "live_fallback")
        XCTAssertFalse(model.canPlayLiveSpeechInstead)
    }

    func testTextImportKeepsLiveSpeechStableWhilePreparedMediaRendersInBackground() async throws {
        let prewarm = PreparedTextAudioPrewarmProbe()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            preparedTextAudioPrewarmHandler: { itemId, title, text, _, _, _ in
                let prepared = await prewarm.prepare(itemId: itemId, title: title, text: text)
                return .success(prepared)
            }
        )
        model.ttsVoiceSelection = .system
        model.resetAndSeed()
        model.importTitle = "Prepared First"
        model.importText = "This text should start immediately while generated audio renders in the background."

        model.importTextItem()
        let request = await prewarm.waitForRequest()

        XCTAssertEqual(model.screen, .playback)
        XCTAssertNotNil(model.snapshot.sessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(model.preparedTextAudioStatus, "rendering")
        XCTAssertEqual(request.title, "Prepared First")

        await prewarm.complete(with: preparedTextAudio(itemId: request.itemId, title: request.title, text: request.text))
        try await waitFor("prepared audio to attach") {
            model.preparedTextAudioStatus == "ready"
        }

        XCTAssertEqual(model.snapshot.preparedTextAudioStatus, "ready")
        XCTAssertEqual(model.snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(model.snapshot.targetId, request.itemId)
        XCTAssertFalse(model.canPlayLiveSpeechInstead)
    }

    func testResumeCompletedSessionAfterExportRequiresExplicitRestart() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Short Item"
        model.importText = "One sentence only."
        model.importTextItem()
        model.skipUnit = "section"
        model.skipForward()
        model.openExport()

        let completedSession = try XCTUnwrap(model.selectedItem.sessions.last)
        model.resumeSession(completedSession)

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.snapshot.targetType, "item_text_tts")
        XCTAssertEqual(model.snapshot.sourceProgressPercent, 100)
        XCTAssertTrue(model.statusMessage.contains("Play from Beginning"))
    }

    func testLifecycleSyncPersistsLatestTextPlaybackPosition() throws {
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.importTitle = "Long Item"
        model.importText = "One. Two. Three."

        model.importTextItem()
        audio.currentOffset = "One. Two. ".count
        model.syncPlaybackProgressForLifecycle()

        let session = try XCTUnwrap(model.selectedItem.sessions.last)
        XCTAssertEqual(session.position.charOffset, "One. Two. ".count)
        XCTAssertEqual(model.snapshot.currentTextStart, "One. Two. ".count)
        XCTAssertEqual(model.diagnostics["playbackLifecycleSync"], "saved")
    }

    func testCompletingFinalAudioAutomaticallyClosesTheSession() throws {
        let audio = WorkflowCompletionAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let completedSessionID = try XCTUnwrap(model.snapshot.sessionId)

        audio.completeCurrentTarget()
        model.syncPlaybackProgressForLifecycle()

        XCTAssertNil(model.snapshot.sessionId)
        XCTAssertEqual(model.screen, .home)
        XCTAssertEqual(model.statusMessage, "Session complete and saved.")
        XCTAssertEqual(model.feedbackEvent?.kind, .success)
        XCTAssertEqual(model.feedbackEvent?.message, "Session complete and saved.")
        XCTAssertEqual(
            model.selectedItem.sessions.first(where: { $0.id == completedSessionID })?.status,
            "finished"
        )
    }

    func testPlaybackSpeechRateChangeRestartsActiveNativeTextAtCurrentOffset() throws {
        let previousSpeechRate = UserDefaults.standard.object(forKey: "speechRate")
        defer {
            if let previousSpeechRate {
                UserDefaults.standard.set(previousSpeechRate, forKey: "speechRate")
            } else {
                UserDefaults.standard.removeObject(forKey: "speechRate")
            }
        }
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.importTitle = "Rate Change"
        model.importText = "One. Two. Three."

        model.importTextItem()
        audio.currentOffset = "One. ".count
        model.speechRate = 0.65
        model.playbackSpeechRateChanged()

        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.currentTextStart, "One. ".count)
        XCTAssertEqual(audio.playedOffsets.last, "One. ".count)
        XCTAssertEqual(try XCTUnwrap(audio.configuredSpeechRates.last), Float(0.65), accuracy: Float(0.001))
        XCTAssertEqual(UserDefaults.standard.double(forKey: "speechRate"), 0.65, accuracy: 0.001)
    }

    func testLegacyEmbeddedPiperModeSanitizesToBundledJamesPath() {
        let defaults = UserDefaults.standard
        let keys = [
            "supertonicTTSMigrationV1",
            "supertonicVoicePendingTermsV1",
            "ttsMode",
            "ttsVoiceSelection",
            SpokenMarginsTerms.acceptanceVersionKey,
            SpokenMarginsTerms.acceptanceDateKey
        ]
        let prior = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                restoreUserDefault(prior[key], forKey: key)
            }
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(audioPlaybackClient: WorkflowRecordingAudioClient())
        model.resetAndSeed()
        model.ttsVoiceSelection = .james
        model.ttsMode = "piper"

        model.speechSettingsChanged()

        XCTAssertEqual(model.ttsMode, "supertonic")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ttsMode"), "supertonic")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ttsVoiceSelection"), "supertonic:M2")
    }

    func testPreOnePointZeroTTSMigrationDefaultsToJamesAndRetainsAppleFallbackVoice() {
        let defaults = UserDefaults.standard
        let keys = [
            "supertonicTTSMigrationV1",
            "ttsMode",
            "ttsVoiceSelection",
            "speechVoiceIdentifier",
            SpokenMarginsTerms.acceptanceVersionKey,
            SpokenMarginsTerms.acceptanceDateKey
        ]
        let prior = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let value = prior[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        defaults.removeObject(forKey: "supertonicTTSMigrationV1")
        defaults.removeObject(forKey: "ttsVoiceSelection")
        defaults.set("piper", forKey: "ttsMode")
        defaults.set("com.apple.ttsbundle.Samantha-compact", forKey: "speechVoiceIdentifier")
        SpokenMarginsTerms.recordAcceptance(in: defaults)

        let model = Gate1AppModel(audioPlaybackClient: WorkflowRecordingAudioClient())

        XCTAssertEqual(model.ttsVoiceSelection, .james)
        XCTAssertEqual(model.ttsMode, "supertonic")
        XCTAssertEqual(model.speechVoiceIdentifier, "com.apple.ttsbundle.Samantha-compact")
        XCTAssertTrue(defaults.bool(forKey: "supertonicTTSMigrationV1"))
    }

    func testVoiceChangeWhilePausedDoesNotCreatePhantomPlaybackProgress() throws {
        let previousVoice = UserDefaults.standard.string(forKey: "speechVoiceIdentifier")
        defer {
            if let previousVoice {
                UserDefaults.standard.set(previousVoice, forKey: "speechVoiceIdentifier")
            } else {
                UserDefaults.standard.removeObject(forKey: "speechVoiceIdentifier")
            }
        }
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.importTitle = "Paused Voice Change"
        model.importText = "One. Two. Three."
        model.importTextItem()
        audio.currentOffset = "One. ".count
        model.pause()
        let playCount = audio.playedOffsets.count

        model.speechVoiceIdentifier = "test.voice"
        model.speechSettingsChanged()

        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.snapshot.currentTextStart, "One. ".count)
        XCTAssertEqual(audio.playedOffsets.count, playCount)
        XCTAssertEqual(audio.configuredSpeechVoices.last!, "test.voice")
    }

    func testSupertonicVoiceChangeStopsPlaybackAndCanResumeFromConfirmedPosition() throws {
        let defaults = UserDefaults.standard
        let keys = [
            "supertonicTTSMigrationV1",
            "supertonicVoicePendingTermsV1",
            "ttsMode",
            "ttsVoiceSelection",
            SpokenMarginsTerms.acceptanceVersionKey,
            SpokenMarginsTerms.acceptanceDateKey
        ]
        let prior = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                restoreUserDefault(prior[key], forKey: key)
            }
        }
        SpokenMarginsTerms.recordAcceptance()
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.importTitle = "Voice switch"
        model.importText = "One sentence. A second sentence follows."
        model.importTextItem()
        audio.currentOffset = "One sentence. ".count
        let playCount = audio.playedOffsets.count

        model.ttsVoiceSelection = .lily
        model.ttsVoiceSelectionChanged()

        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.snapshot.currentTextStart, "One sentence. ".count)
        XCTAssertEqual(audio.playedOffsets.count, playCount)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ttsVoiceSelection"), "supertonic:F2")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ttsMode"), "supertonic")

        model.resumePlayback()

        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.currentTextStart, "One sentence. ".count)
        XCTAssertEqual(audio.playedOffsets.last, "One sentence. ".count)
    }

    private func restoreUserDefault(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testObsidianImportRunsInBackgroundAndLoadsHeadingBasedListeningMap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-markdown-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Structured Article.md")
        try """
        ---
        title: "Structured Article"
        ---
        ### Key takeaways

        Opening content.

        ### 1\\. First section

        First body.

        ### 2\\. Second section

        Second body.
        """.write(to: file, atomically: true, encoding: .utf8)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        model.importObsidianMarkdownFiles(urls: [file])

        XCTAssertTrue(model.isImportingSources)
        try await waitFor("Obsidian import to finish") {
            !model.isImportingSources
        }

        XCTAssertEqual(model.selectedItem.title, "Structured Article")
        XCTAssertEqual(model.selectedItem.chapters.map(\.title), ["Key takeaways", "1. First section", "2. Second section"])
        XCTAssertEqual(model.libraryItems.first(where: { $0.id == model.selectedItem.id })?.status, "Ready to listen")
    }

    #if canImport(UIKit)
    func testTextBasedPDFImportExtractsReadableText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-pdf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Readable PDF.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: file) { context in
            context.beginPage()
            ("A readable PDF paragraph for Spoken Margins." as NSString).draw(
                at: CGPoint(x: 40, y: 40),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
            )
        }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        model.importObsidianMarkdownFiles(urls: [file])
        try await waitFor("PDF import to finish") {
            !model.isImportingSources
        }

        XCTAssertEqual(model.selectedItem.title, "Readable PDF")
        XCTAssertTrue(model.selectedItem.text.contains("A readable PDF paragraph for Spoken Margins."))
    }

    func testPDFVisualHeadingsPrebuildDeterministicListeningMap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-structured-pdf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Structured PDF.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: file) { context in
            context.beginPage()
            var y: CGFloat = 30
            func draw(_ text: String, size: CGFloat, bold: Bool = false) {
                (text as NSString).draw(
                    at: CGPoint(x: 40, y: y),
                    withAttributes: [.font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)]
                )
                y += size + 13
            }
            draw("A Structured Report", size: 26, bold: true)
            for section in ["Context", "Evidence", "Tradeoffs", "Recommendations", "Conclusion"] {
                draw(section, size: 18, bold: true)
                draw("This section contains enough readable body text to establish the ordinary document font size.", size: 12)
            }
        }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        model.importObsidianMarkdownFiles(urls: [file])
        try await waitFor("structured PDF import to finish") {
            !model.isImportingSources
        }

        XCTAssertEqual(model.selectedItem.title, "A Structured Report")
        XCTAssertEqual(model.selectedItem.chapters.map(\.title), ["Context", "Evidence", "Tradeoffs", "Recommendations", "Conclusion"])
        XCTAssertEqual(model.libraryItems.first(where: { $0.id == model.selectedItem.id })?.status, "Ready to listen")
    }
    #endif

    func testPlaybackControlsRemainUsableWhileObsidianImportIsPending() async throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-responsive-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Long Import.md")
        let paragraphs = Array(repeating: "A source paragraph that takes some work to normalize.", count: 2_000)
        try paragraphs.joined(separator: "\n\n").write(to: file, atomically: true, encoding: .utf8)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        XCTAssertEqual(model.snapshot.status, .playing)

        model.importObsidianMarkdownFiles(urls: [file])
        XCTAssertTrue(model.isImportingSources)

        model.playPause()

        XCTAssertEqual(model.snapshot.status, .paused)
        try await waitFor("responsive Obsidian import to finish", timeoutNanoseconds: 5_000_000_000) {
            !model.isImportingSources
        }
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.snapshot.itemId, "item-pill")
        XCTAssertEqual(model.selectedItem.id, "item-pill")
        XCTAssertNotNil(model.libraryItems.first(where: { $0.title == "Long Import" }))
    }

    private func waitFor(
        _ description: String,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        let interval: UInt64 = 10_000_000
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: interval)
            elapsed += interval
        }
        XCTFail("Timed out waiting for \(description).")
    }

    private func preparedTextAudio(itemId: String, title: String, text: String) -> PreparedTextAudio {
        let mediaURL = "file:///tmp/\(itemId)-full.caf"
        return PreparedTextAudio(
            normalizedText: text,
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: mediaURL,
                durationMs: 1_000,
                nativeMediaId: mediaURL
            ),
            timeline: TranscriptTimeline(
                segments: [
                    MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: text.count, text: text)
                ],
                chapters: [
                    MediaTimelineChapter(id: "ch-tts-1", title: title, startMs: 0, transcriptSegmentId: "tts-1")
                ],
                durationMs: 1_000
            ),
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private struct WorkflowFoundationModelStub: LocalFoundationModelClient {
    let configuredAvailability: LocalFoundationModelAvailability
    let summary: String

    init(
        availability: LocalFoundationModelAvailability,
        summary: String = "Local summary"
    ) {
        configuredAvailability = availability
        self.summary = summary
    }

    func availability() -> LocalFoundationModelAvailability {
        configuredAvailability
    }

    func summarizeInterjections(context: String) async throws -> String {
        summary
    }

    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        LocalListeningMapLabel(title: "Chapter \(chapterNumber)", description: "A bounded section description.")
    }

    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String {
        "A bounded local listening map."
    }
}

private struct ThrowingWorkflowFoundationModelStub: LocalFoundationModelClient {
    func availability() -> LocalFoundationModelAvailability {
        .available
    }

    func summarizeInterjections(context: String) async throws -> String {
        throw LocalFoundationModelError.invalidInterjectionSummary
    }

    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        throw LocalFoundationModelError.invalidInterjectionSummary
    }

    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String {
        throw LocalFoundationModelError.invalidInterjectionSummary
    }
}

private actor PreparedTextAudioPrewarmProbe {
    struct Request: Sendable {
        var itemId: String
        var title: String
        var text: String
    }

    private var request: Request?
    private var requestContinuations: [CheckedContinuation<Request, Never>] = []
    private var preparedContinuation: CheckedContinuation<PreparedTextAudio?, Never>?

    func prepare(itemId: String, title: String, text: String) async -> PreparedTextAudio? {
        let request = Request(itemId: itemId, title: title, text: text)
        self.request = request
        for continuation in requestContinuations {
            continuation.resume(returning: request)
        }
        requestContinuations.removeAll()
        return await withCheckedContinuation { continuation in
            preparedContinuation = continuation
        }
    }

    func waitForRequest() async -> Request {
        if let request {
            return request
        }
        return await withCheckedContinuation { continuation in
            requestContinuations.append(continuation)
        }
    }

    func complete(with prepared: PreparedTextAudio?) {
        preparedContinuation?.resume(returning: prepared)
        preparedContinuation = nil
    }
}

private final class WorkflowRecordingAudioClient: AudioPlaybackClient {
    var playedOffsets: [Int] = []
    var configuredSpeechRates: [Float] = []
    var configuredSpeechVoices: [String?] = []
    var currentOffset: Int?
    private var activeTargetId: String?

    func prepareSpeechText(_ text: String) throws -> String {
        SpeechTextNormalizer.normalize(text)
    }

    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {
        configuredSpeechVoices.append(voiceIdentifier)
        configuredSpeechRates.append(rate)
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        activeTargetId = targetId
        currentOffset = charOffset
        playedOffsets.append(charOffset)
    }

    func pause() throws {}

    func currentCharOffset() -> Int? {
        currentOffset
    }

    func currentPlaybackPosition() -> PlaybackPosition? {
        guard let currentOffset else { return nil }
        return PlaybackPosition(
            targetType: .itemTextTTS,
            targetId: activeTargetId,
            textStart: currentOffset,
            textEnd: currentOffset + 1,
            anchorConfidence: .textRange
        )
    }
}

private final class WorkflowCompletionAudioClient: AudioPlaybackClient {
    private let lock = NSLock()
    private var preparedText = ""
    private var activeTargetId: String?
    private var completedTargetId: String?
    private var currentOffset = 0

    func prepareSpeechText(_ text: String) throws -> String {
        let normalized = SpeechTextNormalizer.normalize(text)
        lock.lock()
        preparedText = normalized
        lock.unlock()
        return normalized
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        lock.lock()
        activeTargetId = targetId
        completedTargetId = nil
        currentOffset = charOffset
        lock.unlock()
    }

    func pause() throws {}

    func stop() throws {
        lock.lock()
        activeTargetId = nil
        completedTargetId = nil
        lock.unlock()
    }

    func currentCharOffset() -> Int? {
        lock.lock()
        let offset = currentOffset
        lock.unlock()
        return offset
    }

    func isPlaybackComplete(targetId: String) -> Bool {
        lock.lock()
        let complete = completedTargetId == targetId
        lock.unlock()
        return complete
    }

    func completeCurrentTarget() {
        lock.lock()
        currentOffset = preparedText.count
        completedTargetId = activeTargetId
        lock.unlock()
    }
}
