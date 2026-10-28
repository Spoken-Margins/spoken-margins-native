import Foundation

/// Carries a live-session link (#2833) from `handleIncomingURL` to the live session screen. With no live session
/// screen open the root view presents one; with one open (from the Library's Live row, say) it takes the action.
@MainActor
final class LiveSessionLinkRouter: ObservableObject {
    static let shared = LiveSessionLinkRouter()

    struct Cover: Identifiable, Equatable {
        let id = UUID()
    }

    /// Set when the root view should present the live session screen.
    @Published var cover: Cover?
    /// What the link asked for, until the screen has a loaded session to act on.
    @Published private(set) var pendingAction: LiveSessionDeepLink.Action?
    private var screensOpen = 0

    func open(_ action: LiveSessionDeepLink.Action) {
        pendingAction = action
        if screensOpen == 0, cover == nil { cover = Cover() }
    }

    func screenAppeared() { screensOpen += 1 }

    func screenDisappeared() { screensOpen = max(0, screensOpen - 1) }

    /// Hands over the waiting action once, so a screen that appears later doesn't repeat it.
    func takeAction() -> LiveSessionDeepLink.Action? {
        defer { pendingAction = nil }
        return pendingAction
    }
}
