import Foundation

/// How a listener's first run began (#4711). Stored once in UserDefaults and never rewritten after "first Margin heard".
public enum FirstRunEntry: String, Sendable {
    /// A fresh install the listener opened by itself: Cole's welcome is the first minute.
    case coldInstall = "cold_install"
    /// A friend's file or link held the welcome back.
    case friendArrival = "friend_arrival"
}

/// One time a Margin was heard or shown, as the app saw it. The app decides whose it is from the store, not from a
/// card's label.
public struct MarginHearing: Equatable, Sendable {
    public enum Kind: Sendable { case spoken, written }
    public enum Outcome: Sendable {
        /// A spoken Margin's recording played to its end.
        case reachedEnd
        /// A skip or a stop before the end.
        case stoppedEarly
        /// The recording was missing or would not start.
        case couldNotPlay
        /// A written Margin was saved and shown at its place.
        case savedAndShown
    }

    public let isListenersOwn: Bool
    public let kind: Kind
    public let outcome: Outcome

    public init(isListenersOwn: Bool, kind: Kind, outcome: Outcome) {
        self.isListenersOwn = isListenersOwn
        self.kind = kind
        self.outcome = outcome
    }
}

extension OnboardingProgress {
    /// The rule for the event "first Margin heard": the listener's own spoken Margin played to its end, or their own
    /// written Margin saved and shown. Nobody else's Margin, and no early stop, ever fires it.
    public static func firesFirstMarginHeard(_ hearing: MarginHearing) -> Bool {
        guard hearing.isListenersOwn else { return false }
        switch (hearing.kind, hearing.outcome) {
        case (.spoken, .reachedEnd), (.written, .savedAndShown): return true
        default: return false
        }
    }

    /// Marks `heardFirstMargin` when the rule fires. Returns `.steps` only the first time, so "just fired" is
    /// `change.contains(.steps)`.
    @discardableResult
    public mutating func marginHeard(_ hearing: MarginHearing) -> Change {
        guard Self.firesFirstMarginHeard(hearing) else { return [] }
        return mark([.heardFirstMargin])
    }
}

/// Whether this install has run before, and the one-time migration that keeps upgrades from being asked (#4711).
public enum FirstRunHistory {
    public enum Migration: Equatable, Sendable {
        /// Already ran, or nothing to do.
        case nothing
        /// An upgrade, or a returning listener: mark `heard_first_margin`, store no entry, set the flag.
        case markHeard
        /// A new listener: store `firstRunEntryV1 = cold_install` and set the flag.
        case freshInstall
    }

    /// True when any trace of an earlier run is stored. `welcomeTombstoned` is #4714's tombstone (false until it exists).
    public static func hasRunBefore(
        storedWelcomeSampleVersion: Int,
        storedSteps: [String]?,
        termsAcceptedVersion: String?,
        welcomeTombstoned: Bool
    ) -> Bool {
        storedWelcomeSampleVersion > 0
            || !(storedSteps ?? []).isEmpty
            || termsAcceptedVersion != nil
            || welcomeTombstoned
    }

    /// Runs once per install. `alreadyRan` is the flag `heardFirstMarginMigrationV1`.
    public static func migration(alreadyRan: Bool, libraryWasEmptyAtLaunch: Bool, hasRunBefore: Bool) -> Migration {
        guard !alreadyRan else { return .nothing }
        return !libraryWasEmptyAtLaunch || hasRunBefore ? .markHeard : .freshInstall
    }
}
