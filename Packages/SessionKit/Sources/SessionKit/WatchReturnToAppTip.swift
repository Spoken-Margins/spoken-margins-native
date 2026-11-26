import Foundation

/// What the iPhone knows about a paired Apple Watch (#4563). `WatchMarginReceiver` builds it from `WCSession`; keeping
/// the four facts here lets the rule below be tested on the host, where WatchConnectivity doesn't exist.
public struct WatchPairingState: Equatable, Sendable {
    /// `WCSession.isSupported()`: false on an iPad.
    public var supported: Bool
    /// The session finished activating.
    public var activated: Bool
    /// `WCSession.isPaired`.
    public var paired: Bool
    /// `WCSession.isWatchAppInstalled`: the Spoken Margins Watch app is on the paired Watch.
    public var appInstalled: Bool

    public init(supported: Bool, activated: Bool, paired: Bool, appInstalled: Bool) {
        self.supported = supported
        self.activated = activated
        self.paired = paired
        self.appInstalled = appInstalled
    }

    /// No Watch, or nothing known yet.
    public static let none = WatchPairingState(supported: false, activated: false, paired: false, appInstalled: false)

    /// A paired Watch with the Spoken Margins Watch app on it, known from an activated session.
    public var hasWatchApp: Bool { supported && activated && paired && appInstalled }
}

/// The one-time card that teaches the Watch's own **Return to App** setting (#4563). watchOS lets the listener keep
/// Spoken Margins in front of the clock face (Settings › General › Return to Clock › Spoken Margins), and nobody finds
/// that on their own. The app never forces the Watch app forward; it only says where the setting is, once.
///
/// The card opens on the first quiet moment of a launch that starts with a Margin already saved, so it never sits
/// inside the first run (#4679) and never adds a tap to J11.
public enum WatchReturnToAppTipPolicy {
    /// The flag that the card appeared on this phone. Written when it appears, not when it is asked for, so a dropped
    /// presentation can't lose it and a kill with the card up doesn't bring it back.
    public static let seenKey = "watchReturnToAppTipSeenV1"

    public enum Decision: Equatable, Sendable {
        /// Open the card now.
        case show
        /// Not now: ask again when something changes or at the next launch. Nothing is recorded.
        case wait
        /// Already shown; never again on its own.
        case done
    }

    /// - Parameters:
    ///   - pairing: what the phone knows about the Watch.
    ///   - hasSeen: the card appeared before.
    ///   - hadMarginAtLaunch: the Library already held a Margin when this launch loaded it; nil until it has loaded.
    ///   - calm: the tabs are on screen with nothing presented, no keyboard, nothing recording and no draft open.
    ///   - supertonicDecided: the Supertonic notice has made its decision this launch (it goes first).
    ///   - noticeShownThisLaunch: another one-time notice already opened this launch; at most one does.
    public static func decide(
        pairing: WatchPairingState,
        hasSeen: Bool,
        hadMarginAtLaunch: Bool?,
        calm: Bool,
        supertonicDecided: Bool,
        noticeShownThisLaunch: Bool
    ) -> Decision {
        if hasSeen { return .done }
        // A Watch may be paired or its app installed later, so this is a wait, never a settle.
        guard isOwed(pairing: pairing, hasSeen: hasSeen, hadMarginAtLaunch: hadMarginAtLaunch) else { return .wait }
        guard supertonicDecided, !noticeShownThisLaunch, calm else { return .wait }
        return .show
    }

    /// The card is owed on this launch: a Watch with the app, a Margin already saved at launch, not seen. The app
    /// keeps re-checking for a quiet moment only while this is true.
    public static func isOwed(pairing: WatchPairingState, hasSeen: Bool, hadMarginAtLaunch: Bool?) -> Bool {
        !hasSeen && pairing.hasWatchApp && hadMarginAtLaunch == true
    }
}

/// The path the card and Help both show, in order, so the two can't drift apart. It is the owner's path (#4563):
/// Settings, General, Return to Clock, Spoken Margins, Return to App.
public enum WatchReturnToAppSteps {
    public static let steps: [String] = [
        "Open Settings.",
        "Tap General.",
        "Tap Return to Clock.",
        "Scroll down and tap Spoken Margins.",
        "Turn on Return to App.",
    ]
}
