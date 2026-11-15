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

/// Onboarding progress, the onboarding card and the guided tour's steps (#1020).
extension Gate1AppModel {
    var guidedOnboardingStage: GuidedOnboardingStage { onboardingProgress.stage }

    var isOnboardingCardDismissed: Bool { onboardingProgress.isCardDismissed }

    var onboardingCoreCompletedCount: Int { onboardingProgress.coreCompletedCount }

    var hasCompletedCoreOnboarding: Bool { onboardingProgress.hasCompletedCore }

    var shouldShowOnboardingCard: Bool {
        onboardingProgress.shouldShowCard(
            suppressed: Self.isRunningUnitTests || UITestingHooks.suppressesFirstRun
        )
    }

    /// The coach waits for the prompt even while a friend listen hides it (#3790): hiding the prompt there must not
    /// bring the coach up under the friend's Margin. The coach is otherwise as it was.
    var shouldShowGuidedOnboardingCoach: Bool {
        !isFirstMarginPromptDue
            && onboardingProgress.shouldShowCoach(guidedItemIsSelected: selectedItem.id == Self.guidedOnboardingItemId)
    }

    /// One thing asks for attention at a time (#2852): the prompt and the coach share the Now Playing screen, so the
    /// coach waits for the prompt. The Library strip is on another screen and is never up with the prompt. A friend
    /// listen on this item gives the screen to the friend's Margin, so the prompt is not drawn then (#3790).
    var isFirstMarginPromptShowing: Bool {
        isFirstMarginPromptDue && !friendListenState.isInProgress
    }

    /// The prompt's own rule, before a friend listen is taken into account.
    private var isFirstMarginPromptDue: Bool {
        onboardingProgress.shouldShowFirstMarginPrompt(
            hasActiveSession: hasActiveSession, suppressed: isFirstRunSuppressed
        )
    }

    private var isFirstRunSuppressed: Bool { Self.isRunningUnitTests || UITestingHooks.suppressesFirstRun }

    /// Whether a friend's Margins are playing, or about to, on the item the Now screen shows, read from what the model
    /// already holds (the open item's layers, the pinned card): no store read. The words and rule are `FriendListenState`.
    var friendListenState: FriendListenState {
        // A friend's Margins come from the item's layers and play on the item that is playing, so any other case is no
        // friend listen. This runs on every playback tick, so the cheap answers come before the card is built.
        let layers = selectedItem.importedCommentaryLayers
        guard !layers.isEmpty, selectedItem.id == snapshot.itemId else { return .none }
        let entries = SharedMarginReview.entriesInMemory(
            layers: layers, records: selectedItem.importedCommentaryInterjections, durationMs: selectedItem.mediaDurationMs)
        let entryCount = FriendListenState.aheadCount(
            entries, mediaTimeMs: isMediaPlaybackSnapshot ? (snapshot.currentMediaTimeMs ?? 0) : nil,
            textStart: snapshot.currentTextStart,
            isAtEnd: snapshot.currentPlaybackProgressPercent >= ItemFinishedRule.atEndPercent)
        return FriendListenState(
            selectedItemId: selectedItem.id, playingItemId: snapshot.itemId,
            entryCount: entryCount, pinnedCard: pinnedMarginCard)
    }

    /// The end card asks for a Margin of the listener's own, so it counts as the first-Margin prompt: once it shows, the
    /// prompt does not come back (#3790). The Now screen calls this when the friend-listen state changes.
    func noteFriendListen() {
        guard !isFirstRunSuppressed else { return }
        let state = friendListenState
        changeOnboardingProgress { $0.noteFriendListen(state) }
    }

    /// Either way the prompt has been seen: it does not come back.
    func dismissFirstMarginPrompt() {
        changeOnboardingProgress { $0.firstMarginPromptSeen() }
    }

    /// The prompt's tap: the same Add a Margin as the button below; the microphone line and the written fallback
    /// are that flow's.
    func addFirstMargin() {
        beginInterjection()
        // A tap Add a Margin refused (a save under way, a skim) leaves the prompt for the next try.
        if isRequestingRecordingPermission || snapshot.isRecording { dismissFirstMarginPrompt() }
    }

    func isOnboardingStepComplete(_ step: OnboardingStep) -> Bool {
        onboardingProgress.isComplete(step)
    }

    func markOnboardingSteps(_ steps: Set<OnboardingStep>) {
        changeOnboardingProgress { $0.mark(steps) }
    }

    func setGuidedOnboardingStage(_ stage: GuidedOnboardingStage) {
        changeOnboardingProgress { $0.setStage(stage) }
    }

    /// Applies one transition to a copy, then stores it and writes only the UserDefaults keys it names.
    /// A transition that changes nothing leaves the published value alone, so views are not redrawn for it.
    func changeOnboardingProgress(_ transition: (inout OnboardingProgress) -> OnboardingProgress.Change) {
        var updated = onboardingProgress
        let change = transition(&updated)
        guard !change.isEmpty else { return }
        onboardingProgress = updated
        if change.contains(.steps) {
            UserDefaults.standard.set(updated.storedSteps, forKey: Self.onboardingStepsKey)
        }
        if change.contains(.stage) {
            UserDefaults.standard.set(updated.storedStage, forKey: Self.guidedOnboardingStageKey)
        }
        if change.contains(.card) {
            UserDefaults.standard.set(updated.isCardDismissed, forKey: Self.onboardingCardDismissedKey)
        }
    }

    /// `items` are the Library's live items, taken from the read the caller already made (#2507).
    func reconcileOnboardingEvidence(items: [LibraryItemSummary], store: SQLiteSessionStore) throws {
        var evidence = OnboardingEvidenceClassifier.sourceSteps(items: items)
        if try store.hasActiveInterjection() {
            evidence.insert(.firstInterjection)
        }
        markOnboardingSteps(evidence)
    }

    func dismissOnboardingCard() {
        changeOnboardingProgress { $0.dismissCard() }
    }

    func restoreOnboardingCard() {
        changeOnboardingProgress { $0.restoreCard() }
    }

    func pauseGuidedOnboarding() {
        setGuidedOnboardingStage(.inactive)
    }

    func continueGuidedOnboardingPastAI() {
        changeOnboardingProgress { $0.continuePastAI() }
    }

    func finishGuidedOnboarding() {
        setGuidedOnboardingStage(.inactive)
    }

    func recordTimelineInterjectionViewed(interjectionId: String) {
        guard selectedItem.interjections.contains(where: { $0.id == interjectionId }) else { return }
        recordTimelineReviewCompleted()
    }

    func recordTimelineReviewCompleted() {
        changeOnboardingProgress { $0.timelineReviewed() }
    }

    func recordSessionExported() {
        guard exportSessionId != nil else { return }
        changeOnboardingProgress { $0.sessionExported() }
    }

    func resetOnboardingProgressForTesting() {
        guard Self.isRunningUnitTests else { return }
        onboardingProgress = OnboardingProgress(storedSteps: nil, storedStage: nil, isCardDismissed: false)
        UserDefaults.standard.removeObject(forKey: Self.onboardingStepsKey)
        UserDefaults.standard.removeObject(forKey: Self.guidedOnboardingStageKey)
        UserDefaults.standard.removeObject(forKey: Self.onboardingCardDismissedKey)
    }
}
