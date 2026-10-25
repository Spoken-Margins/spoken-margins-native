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
            suppressed: Self.isRunningUnitTests || UITestingHooks.isActive
        )
    }

    var shouldShowGuidedOnboardingCoach: Bool {
        onboardingProgress.shouldShowCoach(guidedItemIsSelected: selectedItem.id == Self.guidedOnboardingItemId)
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

    func reconcileOnboardingEvidence(store: SQLiteSessionStore) throws {
        let items = try store.listItemSummaries()
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

    func openAISettingsFromOnboarding() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_ai_settings_from_onboarding") else { return }
        continueGuidedOnboardingPastAI()
        isHelpPresented = false
        showSettingsTab()
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
