import Foundation

/// Where a listener can say their Margins should go (#4672). The raw values are stored in UserDefaults on the
/// phone and nowhere else: never in a packet, an export, Diagnostics or sync.
public enum MarginDestination: String, CaseIterable, Sendable {
    case keepHere = "keep_here"
    case notes
    case person
    case ai
    case club
}

/// The line under the rows of the "A person" step.
public enum PersonNote: Equatable, Sendable {
    /// The Margin is on the welcome item, which can't be shared.
    case welcomeStaysHere
    /// The Settings version: how to share a Margin later.
    case shareFromMarginsTab
}

/// The one setup an answer leads to. `.none` is "nothing to open": Keep it here, or an answer that was refused.
public enum MarginDestinationSetup: Equatable, Sendable {
    case none
    case notesStep
    case personStep(sendThisMargin: Bool, findSomething: Bool, note: PersonNote?)
    case aiExport
}

/// Rows under "More to try". They record no answer.
public enum MoreToTryRow: Equatable, Sendable {
    case bringMyShows
    case findSomething
    case meetings
}

/// The question "Where should this go?" asked once after the first Margin has played back, and the Settings row
/// that reopens it. Plain logic over UserDefaults, like `OnboardingProgress`: the app builds one per sheet and
/// calls it; it shows nothing itself. A new instance is a new sheet, so a relaunch or a reopened Settings sheet
/// starts with a fresh burst guard.
public final class MarginDestinationQuestion {
    static let answerKey = "marginDestinationV1"
    static let presentedKey = "marginDestinationPresentedV1"
    static let skippedValue = "skipped"

    /// What the screen knows about the Margin and where the sheet was opened from.
    public struct Context: Equatable, Sendable {
        public var marginOffersShare: Bool
        public var isWelcomeItem: Bool
        public var quizAvailable: Bool
        public var fromSettings: Bool
        public var clubScreenExists: Bool

        public init(
            marginOffersShare: Bool = false,
            isWelcomeItem: Bool = false,
            quizAvailable: Bool = false,
            fromSettings: Bool = false,
            clubScreenExists: Bool = false
        ) {
            self.marginOffersShare = marginOffersShare
            self.isWelcomeItem = isWelcomeItem
            self.quizAvailable = quizAvailable
            self.fromSettings = fromSettings
            self.clubScreenExists = clubScreenExists
        }
    }

    private let defaults: UserDefaults
    private var answeredThisSheet = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: When to ask

    /// True only when every condition holds. Shown counts as asked (`markPresented`), and an answer or a skip
    /// also means it was asked, so a kill mid-sheet never nags.
    ///
    /// `speechAskOutstanding` is true while the in-app Speech Recognition card (#4715, condition 6) is due and
    /// not yet answered, whether or not it is on screen right now, and it stays true across a relaunch until the
    /// listener answers: the inline card first, this sheet after. The caller derives it from the card's own
    /// stored state; this type keeps none of it.
    public func shouldPresent(
        firstMarginHeardColdInstall: Bool,
        appActive: Bool,
        somethingPresented: Bool,
        recording: Bool,
        speechAskOutstanding: Bool,
        friendShareCardShowing: Bool
    ) -> Bool {
        firstMarginHeardColdInstall
            && appActive
            && !somethingPresented
            && !recording
            && !speechAskOutstanding
            && !friendShareCardShowing
            && !defaults.bool(forKey: Self.presentedKey)
            && storedAnswer == nil
    }

    public func markPresented() {
        defaults.set(true, forKey: Self.presentedKey)
    }

    // MARK: What to show

    /// The answers to list, in order. A person shows only when it has a setup (Send this Margin, or the quiz),
    /// or, in Settings, when it is the current answer. A class or a club shows only once it has a screen.
    public func visibleAnswers(context: Context) -> [MarginDestination] {
        MarginDestination.allCases.filter { isVisible($0, context: context) }
    }

    public func moreToTry(quizAvailable: Bool, meetingsAvailable: Bool) -> [MoreToTryRow] {
        var rows: [MoreToTryRow] = [.bringMyShows]
        if quizAvailable { rows.append(.findSomething) }
        if meetingsAvailable { rows.append(.meetings) }
        return rows
    }

    // MARK: Answering

    /// Records the answer and returns its one setup. Returns `.none` and records nothing for an answer that is
    /// hidden, for a second tap in the same sheet, and, outside Settings, once an answer is already stored.
    public func answer(_ destination: MarginDestination, context: Context) -> MarginDestinationSetup {
        guard !answeredThisSheet else { return .none }
        guard context.fromSettings || storedAnswer == nil else { return .none }
        guard isVisible(destination, context: context) else { return .none }
        answeredThisSheet = true
        defaults.set(destination.rawValue, forKey: Self.answerKey)
        switch destination {
        case .keepHere, .club:
            return .none
        case .notes:
            return .notesStep
        case .ai:
            return .aiExport
        case .person:
            let note: PersonNote? = context.isWelcomeItem
                ? .welcomeStaysHere
                : (context.fromSettings ? .shareFromMarginsTab : nil)
            return .personStep(
                sendThisMargin: Self.offersSend(context),
                findSomething: context.quizAvailable,
                note: note
            )
        }
    }

    /// Not now, or swipe down. Records "skipped" and never replaces an answer. In Settings, Cancel records nothing.
    public func skip(context: Context) {
        guard !context.fromSettings, storedAnswer == nil else { return }
        defaults.set(Self.skippedValue, forKey: Self.answerKey)
    }

    // MARK: What was chosen

    /// Nil for skipped, never asked or a value this build doesn't know.
    public var current: MarginDestination? {
        storedAnswer.flatMap(MarginDestination.init(rawValue:))
    }

    /// The value on the Settings row.
    public var settingsValue: String {
        switch current {
        case .keepHere: return "Here"
        case .notes: return "My notes"
        case .person: return "A person"
        case .ai: return "An AI"
        case .club, nil: return "Not chosen"
        }
    }

    // MARK: Private

    private var storedAnswer: String? {
        defaults.string(forKey: Self.answerKey)
    }

    private static func offersSend(_ context: Context) -> Bool {
        context.marginOffersShare && !context.isWelcomeItem
    }

    private func isVisible(_ destination: MarginDestination, context: Context) -> Bool {
        switch destination {
        case .keepHere, .notes, .ai:
            return true
        case .person:
            return Self.offersSend(context)
                || context.quizAvailable
                || (context.fromSettings && current == .person)
        case .club:
            return context.clubScreenExists
        }
    }
}
