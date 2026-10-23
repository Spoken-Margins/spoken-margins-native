import Foundation

/// What a listener has done that the Help card and the guided tour count.
///
/// The raw values are stored in UserDefaults by every build since the tour shipped, so they
/// must not change.
public enum OnboardingStep: String, CaseIterable, Identifiable, Hashable, Sendable {
    case firstInterjection = "first_interjection"
    case reviewedTimeline = "reviewed_timeline"
    case exportedSession = "exported_session"
    case addedOwnSource = "added_own_source"
    case addedFromSafari = "added_from_safari"
    case addedFromFiles = "added_from_files"
    case addedPodcast = "added_podcast"

    public var id: String { rawValue }

    public static let core: [OnboardingStep] = [
        .firstInterjection,
        .reviewedTimeline,
        .exportedSession
    ]

    public static let sourceExploration: [OnboardingStep] = [
        .addedOwnSource,
        .addedFromSafari,
        .addedFromFiles,
        .addedPodcast
    ]
}

/// Where the guided tour is. Stored by raw value, like `OnboardingStep`.
public enum GuidedOnboardingStage: String, Equatable, Sendable {
    case inactive
    case practiceInterjection = "practice_interjection"
    case reviewTimeline = "review_timeline"
    case optionalAI = "optional_ai"
    case exportSession = "export_session"
    case complete
}

/// The Help card's progress and the guided tour's stage, with the rules that move them (P30 of
/// the Gate1AppModel split, #1019).
///
/// This is a plain value. The app holds one, asks it to change, and writes to UserDefaults only
/// what the returned `Change` names. That keeps the old write rules: marking steps writes only
/// when the set grew, while setting the stage or the card flag writes every time.
public struct OnboardingProgress: Equatable, Sendable {
    /// What a transition changed, so the owner of the value knows what to store.
    public struct Change: OptionSet, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// The completed steps grew.
        public static let steps = Change(rawValue: 1 << 0)
        /// The tour stage was set (even to the stage it was already in).
        public static let stage = Change(rawValue: 1 << 1)
        /// The card was dismissed or restored (even to the state it was already in).
        public static let card = Change(rawValue: 1 << 2)
    }

    public private(set) var completedSteps: Set<OnboardingStep>
    public private(set) var stage: GuidedOnboardingStage
    public private(set) var isCardDismissed: Bool

    /// Reads what UserDefaults holds. Step names this build does not know are dropped, and a
    /// missing or unknown stage reads as `inactive`.
    public init(storedSteps: [String]?, storedStage: String?, isCardDismissed: Bool) {
        completedSteps = Set((storedSteps ?? []).compactMap(OnboardingStep.init(rawValue:)))
        stage = storedStage.flatMap(GuidedOnboardingStage.init(rawValue:)) ?? .inactive
        self.isCardDismissed = isCardDismissed
    }

    /// The completed steps as UserDefaults stores them: raw values, sorted.
    public var storedSteps: [String] {
        completedSteps.map(\.rawValue).sorted()
    }

    /// The stage as UserDefaults stores it.
    public var storedStage: String {
        stage.rawValue
    }

    // MARK: Queries

    public var coreCompletedCount: Int {
        OnboardingStep.core.filter(completedSteps.contains).count
    }

    public var hasCompletedCore: Bool {
        coreCompletedCount == OnboardingStep.core.count
    }

    public func isComplete(_ step: OnboardingStep) -> Bool {
        completedSteps.contains(step)
    }

    /// `suppressed` is true under unit tests and UI tests, which must not see the card.
    public func shouldShowCard(suppressed: Bool) -> Bool {
        !suppressed && !hasCompletedCore && !isCardDismissed
    }

    public func shouldShowCoach(guidedItemIsSelected: Bool) -> Bool {
        stage != .inactive && guidedItemIsSelected
    }

    /// The stage "Start or Resume Guided Tour" puts the tour in. A listener who has finished the
    /// core steps starts over from the first one.
    public var tourResumeStage: GuidedOnboardingStage {
        if hasCompletedCore {
            return .practiceInterjection
        } else if !isComplete(.firstInterjection) {
            return .practiceInterjection
        } else if !isComplete(.reviewedTimeline) {
            return .reviewTimeline
        } else if !isComplete(.exportedSession) {
            return .optionalAI
        } else {
            // Not reachable today: all three core steps complete is caught first. Kept as the
            // chain was written.
            return .complete
        }
    }

    // MARK: Transitions

    /// Adds steps. Reports `steps` only when the set grew.
    @discardableResult
    public mutating func mark(_ steps: Set<OnboardingStep>) -> Change {
        let updated = completedSteps.union(steps)
        guard updated != completedSteps else { return [] }
        completedSteps = updated
        return .steps
    }

    @discardableResult
    public mutating func setStage(_ newStage: GuidedOnboardingStage) -> Change {
        stage = newStage
        return .stage
    }

    /// "Continue" past the optional AI step. Only the AI stage moves on.
    @discardableResult
    public mutating func continuePastAI() -> Change {
        guard stage == .optionalAI else { return [] }
        return setStage(.exportSession)
    }

    /// The listener saved a Margin. Only the practice stage advances.
    @discardableResult
    public mutating func firstInterjectionSaved() -> Change {
        var change = mark([.firstInterjection])
        if stage == .practiceInterjection {
            change.formUnion(setStage(.reviewTimeline))
        }
        return change
    }

    /// The listener looked at a Margin on the timeline. Only the review stage advances.
    @discardableResult
    public mutating func timelineReviewed() -> Change {
        var change = mark([.reviewedTimeline])
        if stage == .reviewTimeline {
            change.formUnion(setStage(.optionalAI))
        }
        return change
    }

    /// The listener exported a session. Only the export stage advances.
    @discardableResult
    public mutating func sessionExported() -> Change {
        var change = mark([.exportedSession])
        if stage == .exportSession {
            change.formUnion(setStage(.complete))
        }
        return change
    }

    @discardableResult
    public mutating func dismissCard() -> Change {
        isCardDismissed = true
        return .card
    }

    @discardableResult
    public mutating func restoreCard() -> Change {
        isCardDismissed = false
        return .card
    }
}

/// Reads the Library for the source steps the listener has already done: sources they added, not the ones the app seeds.
public enum OnboardingEvidenceClassifier {
    /// The sample and the tour item the app seeds. Adding these is not the listener adding a source.
    public static let defaultSeededItemIDs: Set<String> = [
        "item-spoken-margins-overview",
        "guided-onboarding"
    ]

    public static func sourceSteps(
        items: [some LibraryItemFields],
        seededItemIDs: Set<String> = defaultSeededItemIDs
    ) -> Set<OnboardingStep> {
        let userItems = items.filter { !seededItemIDs.contains($0.id) }
        var evidence: Set<OnboardingStep> = []
        if !userItems.isEmpty {
            evidence.insert(.addedOwnSource)
        }
        if userItems.contains(where: { $0.mediaType == "text" && $0.externalReferenceType == "url" }) {
            evidence.formUnion([.addedOwnSource, .addedFromSafari])
        }
        if userItems.contains(where: { $0.externalReferenceType == "file" }) {
            evidence.formUnion([.addedOwnSource, .addedFromFiles])
        }
        return evidence
    }
}
