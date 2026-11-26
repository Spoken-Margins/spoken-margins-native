import Foundation

/// #3291 (done-when 4): on a first launch opened from a friend's file, the friend's item comes first. "Follow a few
/// favourites" (the first-run catalog drawer) and the Welcome article it plays on Done wait until the friend has
/// opened that item and come back to the Library.
///
/// The drawer used to open as the root view appeared, while the system was still handing the file over, so the
/// two raced. Now the drawer waits for the launch to settle (a file the system hands over arrives by then); a file
/// that arrives later still closes an untouched drawer and takes its place. Once the friend's item has opened, the
/// drawer opens the next time the listener is on the Library. If that never happens in this launch (the file was
/// refused, the import cancelled, the app closed), the drawer is owed to the next launch, even though the Library
/// is no longer empty by then.
///
/// The drawer opens once more in that case, and nothing plays when it closes with nothing picked (#3795, #3796): the
/// listener has a friend's episode and a reason to be here, so the Welcome sample is not played over it. The held-back
/// state is spent when the drawer opens, so a drawer left open when the app is killed is not owed again.
///
/// Terms are not part of this order: they show only on the first on-device voice playback, as before.
public struct FirstLaunchWelcomeOrder: Equatable, Sendable {
    /// Where the listener is when something changes.
    public enum Place: Equatable, Sendable {
        /// The tabs, with no other sheet up.
        case library
        /// An item's own screen.
        case item
        /// Anything else: the player, the Timeline, a sheet such as the import review or Terms.
        case elsewhere
    }

    public enum Action: Equatable, Sendable {
        case none
        case presentDrawer
        /// Close the drawer without marking it seen: it opens again after the friend's item.
        case withdrawDrawer
        /// Play the bundled welcome now, where the listener is (#4711 Design section 3). Once per owed welcome.
        case playWelcome
    }

    public enum Phase: Equatable, Sendable {
        /// The drawer doesn't open by itself in this launch.
        case notOwed
        /// The drawer is owed and waits for the launch to settle on the Library.
        case owed
        case drawerShowing
        /// A friend's file arrived; the drawer waits for its item to open.
        case waitingForFriendItem
        /// The friend's item opened; the drawer waits for the Library.
        case waitingForLibrary
    }

    public private(set) var phase: Phase
    public private(set) var isSettled = false
    /// A friend's file held the drawer back, in this launch or an earlier one. Stays true once the drawer shows.
    public private(set) var wasHeldBack: Bool
    /// An earlier launch's friend's file held the drawer back; a failure in this launch doesn't undo that.
    private let wasHeldBackBeforeThisLaunch: Bool
    /// The drawer is owed although the Library will not be empty at the next launch: a friend's file failed, and the
    /// drawer it withdrew has not shown since.
    private var isOwedAfterFailure: Bool
    /// A friend's file opened its item in this launch (the import's signal, #4834). Stays true once set; the Follow
    /// card remembers that item as the arrival item (#4672).
    public private(set) var reachedFriendItem = false
    /// The cold-install welcome is owed and waits for the launch to settle (#4711 Design section 3, `welcomeOwed`).
    public private(set) var welcomeOwed: Bool
    /// A friend's file took the welcome's place in this launch; a failed file gives it back.
    private var welcomeHeldByFile = false
    /// The welcome has started in this launch, so a file that arrives later doesn't change the entry (Default taken 2).
    private var welcomePlayed = false

    /// What the app keeps for the next launch, in case this one ends now.
    public enum Carry: Equatable, Sendable {
        case nothing
        /// The drawer is owed, and Done with nothing picked plays the Welcome sample: no friend's item came of it.
        case drawerOwed
        /// The drawer is owed and held back: a friend's item is in the Library, so Done with nothing picked plays nothing.
        case drawerHeldBack
    }

    /// Before the drawer has shown, a friend's file that is waiting (or that came in an earlier launch) carries it held
    /// back; one that failed carries it owed but not held back (the audit on PR #4597). Once it shows, nothing is carried.
    public var carry: Carry {
        switch phase {
        case .waitingForFriendItem, .waitingForLibrary:
            return .drawerHeldBack
        case .owed where wasHeldBack:
            return .drawerHeldBack
        case .owed where isOwedAfterFailure:
            return .drawerOwed
        case .owed, .notOwed, .drawerShowing:
            return .nothing
        }
    }

    /// Whether Done with nothing picked (or a pick that couldn't start) may play the Welcome sample. It may not
    /// when a friend's file held the drawer back (#3796).
    public var playsWelcomeSampleOnClose: Bool { !wasHeldBack }

    /// How this first run began (#4711 Design section 3, `entry`): `.friendArrival` when a friend's file held the
    /// welcome (or the drawer) back, else `.coldInstall`. A file that arrives after the welcome has played doesn't
    /// change it (Default taken 2). The app stores it while "first Margin heard" hasn't fired.
    public var entry: FirstRunEntry { wasHeldBack && !welcomePlayed ? .friendArrival : .coldInstall }

    /// Whether this launch owes the drawer. A fresh install owes it (the Library was empty before the Welcome
    /// sample was added), and so does a launch after one whose friend's file kept it waiting.
    public static func drawerOwed(
        libraryWasEmptyAtLaunch: Bool,
        deferredFromEarlierLaunch: Bool,
        hasSeenDrawer: Bool,
        followedSourceCount: Int
    ) -> Bool {
        FirstRunCatalogDrawerPolicy.opensAutomatically(
            libraryWasEmptyAtLaunch: libraryWasEmptyAtLaunch || deferredFromEarlierLaunch,
            hasSeenDrawer: hasSeenDrawer,
            followedSourceCount: followedSourceCount
        )
    }

    /// - Parameters:
    ///   - owedFromEarlierLaunch: an earlier launch's friend's file kept the drawer waiting and the app was left before
    ///     it showed; the drawer is owed now and counts as held back.
    ///   - owedAfterEarlierFailure: an earlier launch's friend's file failed and the app was left before the drawer it
    ///     withdrew came back; the drawer is owed now and is not held back.
    ///   - welcomeOwed: a cold install owes the bundled welcome, played on settle with no Play tap (#4711 Design section 3;
    ///     #4714 builds the order with it). Defaults to false, so every existing caller is unchanged. An earlier launch's
    ///     held-back friend's file means it isn't owed.
    public init(
        drawerOwed: Bool,
        owedFromEarlierLaunch: Bool = false,
        owedAfterEarlierFailure: Bool = false,
        welcomeOwed: Bool = false
    ) {
        self.welcomeOwed = welcomeOwed && !(drawerOwed && owedFromEarlierLaunch)
        phase = drawerOwed ? .owed : .notOwed
        wasHeldBack = drawerOwed && owedFromEarlierLaunch
        wasHeldBackBeforeThisLaunch = wasHeldBack
        isOwedAfterFailure = drawerOwed && owedAfterEarlierFailure
    }

    /// The drawer is still owed while a friend's file holds it back; the app keeps that for the next launch.
    public var defersDrawer: Bool {
        phase == .waitingForFriendItem || phase == .waitingForLibrary
    }

    /// The launch has had time for the system to hand over a file it opened the app with.
    public mutating func settle(at place: Place) -> Action {
        isSettled = true
        return moved(to: place)
    }

    /// A friend's file (a `.spokenmargins` packet or a share link) arrived. An untouched drawer is withdrawn so the
    /// file comes first; one the listener has already picked shows in stays, and the file's item opens under it.
    public mutating func friendFileArrived(drawerHasPicks: Bool) -> Action {
        if welcomeOwed {
            welcomeOwed = false
            welcomeHeldByFile = true
            wasHeldBack = true
        }
        switch phase {
        case .owed:
            phase = .waitingForFriendItem
            wasHeldBack = true
            return .none
        case .drawerShowing:
            guard !drawerHasPicks else { return .none }
            phase = .waitingForFriendItem
            wasHeldBack = true
            return .withdrawDrawer
        case .notOwed, .waitingForFriendItem, .waitingForLibrary:
            return .none
        }
    }

    /// A friend's link or file failed to open and the sheet saying so was closed with OK or Close (#3801), not on Try
    /// Again, which stays waiting. The drawer the file withdrew comes back: at once when the listener is on the
    /// Library and the launch has settled, else owed to the next time they reach it. It no longer counts as held
    /// back because of this file, so Done with nothing picked plays the Welcome sample as on any first launch, unless
    /// an earlier launch's friend's file held it back (that friend's item is in the Library). A failure with the drawer
    /// never withdrawn (it had picks, or nothing was owed) changes nothing.
    public mutating func friendFileFailed(place: Place) -> Action {
        // Once the friend's item has opened (`friendItemOpened`) the phase is waitingForLibrary and a failure changes nothing.
        let drawerWaiting = phase == .waitingForFriendItem
        guard drawerWaiting || welcomeHeldByFile else { return .none }
        wasHeldBack = wasHeldBackBeforeThisLaunch
        if drawerWaiting {
            isOwedAfterFailure = true
            phase = .owed
        }
        if welcomeHeldByFile {
            // Owed again unless an earlier launch's file held it back (the same rule as the drawer).
            welcomeHeldByFile = false
            welcomeOwed = !wasHeldBackBeforeThisLaunch
        }
        return moved(to: place)
    }

    /// A friend's file imported and opened its item (the import's own signal, not the listener's place). From now on a
    /// failure of another link does not undo the hold-back: that item is in the Library (#4834).
    public mutating func friendItemOpened() {
        if welcomeHeldByFile {
            // The welcome's place was taken by this file, which has now opened: a later failure doesn't give it back.
            welcomeHeldByFile = false
            reachedFriendItem = true
        }
        guard phase == .waitingForFriendItem || phase == .waitingForLibrary else { return }
        reachedFriendItem = true
        phase = .waitingForLibrary
    }

    /// The listener's place changed.
    public mutating func moved(to place: Place) -> Action {
        // The welcome goes first and plays wherever the listener is; it doesn't wait for the Library (Design: "any
        // settled place counts"). If the drawer is owed too, it waits for the next Library visit (Default taken 5).
        if welcomeOwed, isSettled, phase != .waitingForFriendItem, phase != .waitingForLibrary {
            welcomeOwed = false
            welcomePlayed = true
            return .playWelcome
        }
        switch phase {
        case .owed, .waitingForLibrary:
            guard isSettled, place == .library else { return .none }
            phase = .drawerShowing
            return .presentDrawer
        case .waitingForFriendItem:
            // Only the import's own signal (`friendItemOpened`) advances this: an item the listener opened themselves,
            // or one still downloading, is not the friend's, and going back to the Library must not bring the drawer.
            return .none
        case .notOwed, .drawerShowing:
            return .none
        }
    }

    /// The drawer closed however it closed, other than being withdrawn: it doesn't open by itself again.
    public mutating func drawerClosed() {
        if phase == .drawerShowing { phase = .notOwed }
    }
}
