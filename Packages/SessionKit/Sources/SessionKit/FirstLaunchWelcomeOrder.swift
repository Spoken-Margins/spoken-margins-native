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

    /// Whether Done with nothing picked (or a pick that couldn't start) may play the Welcome sample. It may not
    /// when a friend's file held the drawer back (#3796).
    public var playsWelcomeSampleOnClose: Bool { !wasHeldBack }

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

    /// - Parameter owedFromEarlierLaunch: an earlier launch's friend's file kept the drawer waiting and the app was
    ///   left before it showed; the drawer is owed now and counts as held back.
    public init(drawerOwed: Bool, owedFromEarlierLaunch: Bool = false) {
        phase = drawerOwed ? .owed : .notOwed
        wasHeldBack = drawerOwed && owedFromEarlierLaunch
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

    /// The listener's place changed.
    public mutating func moved(to place: Place) -> Action {
        switch phase {
        case .owed, .waitingForLibrary:
            guard isSettled, place == .library else { return .none }
            phase = .drawerShowing
            return .presentDrawer
        case .waitingForFriendItem:
            if place == .item { phase = .waitingForLibrary }
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
