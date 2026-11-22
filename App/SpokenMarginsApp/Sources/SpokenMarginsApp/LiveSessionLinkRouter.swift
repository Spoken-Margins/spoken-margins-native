import Foundation
import SwiftUI

/// Carries a live-session link (#2833) from `handleIncomingURL` to the live session screen. With no screen showing
/// the running session the root view presents one; with one open (from the Library's Live row, say) it takes the
/// action. A link nobody acts on soon is dropped, so it never starts a Margin the listener didn't just ask for.
///
/// It is also the one presenter for the Library's Live row (#4091). A cover presented from inside a Library list row
/// was dismissed and presented again whenever the list re-hosted that row, which built a new screen each time: the
/// listener saw the setup card flash and the End Session sheet close before it could be answered. The root view is
/// never re-hosted, so the screen presented from it stays up until it is closed.
@MainActor
final class LiveSessionLinkRouter: ObservableObject {
    static let shared = LiveSessionLinkRouter()

    struct Cover: Identifiable, Equatable {
        let id = UUID()
        /// The session to open (from the Live row); nil opens the running one, or the setup card.
        var sessionId: String?
        /// The window whose Live row asked (`liveSessionWindow`); only that window presents it. Nil (a link) is every
        /// window's.
        var window: UUID?
    }

    /// How long a link waits for a screen to load before it is dropped.
    static let timeToLive: TimeInterval = 10
    /// How long the root view gets to present a screen before the link is given up (another cover can block it).
    static let presentationGrace: Duration = .seconds(2)

    /// Set when the root view should present the live session screen. Dismissing the screen drops any waiting link.
    @Published var cover: Cover? {
        didSet { if cover == nil { pendingAction = nil } }
    }
    /// What the link asked for, until the screen has a loaded session to act on.
    @Published private(set) var pendingAction: LiveSessionDeepLink.Action?
    private var pendingSince = Date.distantPast
    private var screensOpen = 0

    /// Takes a live-session link from `onOpenURL`; false for any other URL, which the model handles.
    func handle(_ url: URL) -> Bool {
        guard let action = LiveSessionDeepLink.action(from: url) else { return false }
        open(action)
        return true
    }

    func open(_ action: LiveSessionDeepLink.Action, now: Date = Date()) {
        pendingAction = action
        pendingSince = now
        guard screensOpen == 0 else { return }
        let presented = Cover()
        cover = presented
        Task { [weak self] in
            try? await Task.sleep(for: Self.presentationGrace)
            // Only the cover this link set: a screen the listener opened since is not the link's to close.
            guard let self, screensOpen == 0, cover?.id == presented.id else { return }
            cover = nil // nothing appeared: another cover blocked it, and the next link must try again
        }
    }

    /// Opens a session's screen from the Library's Live row, in the row's window. No link waits on it, so nothing closes
    /// it but the screen.
    func openScreen(sessionId: String, window: UUID?) {
        pendingAction = nil
        cover = Cover(sessionId: sessionId, window: window)
    }

    /// Opens the live session screen on its start card, for Record a Margin with nothing running (#4923). No link waits
    /// on it, so nothing closes it but the screen: `open` would drop the cover after `presentationGrace`, because a
    /// start card never registers as a running screen.
    func openStartCard() {
        pendingAction = nil
        cover = Cover(sessionId: nil, window: nil)
    }

    /// A screen showing the running session appeared or went away.
    func runningScreenAppeared() { screensOpen += 1 }

    func runningScreenDisappeared() { screensOpen = max(0, screensOpen - 1) }

    /// Hands over the waiting action once, unless it has waited too long.
    func takeAction(now: Date = Date()) -> LiveSessionDeepLink.Action? {
        defer { pendingAction = nil }
        guard now.timeIntervalSince(pendingSince) <= Self.timeToLive else { return nil }
        return pendingAction
    }
}

/// Presents the live session screen for a live-session link that finds none open, and for the Library's Live row. A modifier of its own so the root view,
/// which is size-capped, gains no lines for it.
///
/// Every window's root has one, and they share the router. A Live row's screen is presented only in the row's window:
/// presented in each, it was two screens for one session, and closing either closed both (#4091).
private struct LiveSessionLinkCover: ViewModifier {
    @ObservedObject private var links = LiveSessionLinkRouter.shared
    /// Made once for each window, because a `WindowGroup`'s content is built once for each scene and keeps its state.
    @State private var window = UUID()
    let model: Gate1AppModel

    func body(content: Content) -> some View {
        content
            .environment(\.liveSessionWindow, window)
            .trackedFullScreenCover(item: windowsCover) { cover in
                // `.equatable()` so the root's redraw on each model publish stops here (#4091).
                LiveSessionView(model: model, sessionId: cover.sessionId).equatable()
            }
    }

    private var windowsCover: Binding<LiveSessionLinkRouter.Cover?> {
        Binding {
            links.cover.flatMap { $0.window == nil || $0.window == window ? $0 : nil }
        } set: { newValue in
            guard newValue == nil, let shown = links.cover, shown.window == nil || shown.window == window else { return }
            links.cover = nil
        }
    }
}

extension View {
    func liveSessionLinkCover(_ model: Gate1AppModel) -> some View {
        modifier(LiveSessionLinkCover(model: model))
    }
}

extension EnvironmentValues {
    /// The window a view is in, for `LiveSessionLinkRouter.openScreen`; set by the window root's `liveSessionLinkCover`.
    @Entry var liveSessionWindow: UUID?
}
