import Foundation
import SwiftUI

/// Carries a live-session link (#2833) from `handleIncomingURL` to the live session screen. With no screen showing
/// the running session the root view presents one; with one open (from the Library's Live row, say) it takes the
/// action. A link nobody acts on soon is dropped, so it never starts a Margin the listener didn't just ask for.
@MainActor
final class LiveSessionLinkRouter: ObservableObject {
    static let shared = LiveSessionLinkRouter()

    struct Cover: Identifiable, Equatable {
        let id = UUID()
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
        cover = Cover()
        Task { [weak self] in
            try? await Task.sleep(for: Self.presentationGrace)
            guard let self, screensOpen == 0 else { return }
            cover = nil // nothing appeared: another cover blocked it, and the next link must try again
        }
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

/// Presents the live session screen when a live-session link finds none open. A modifier of its own so the root view,
/// which is size-capped, gains no lines for it.
private struct LiveSessionLinkCover: ViewModifier {
    @ObservedObject private var links = LiveSessionLinkRouter.shared
    let model: Gate1AppModel

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $links.cover) { _ in
            LiveSessionView().environmentObject(model)
        }
    }
}

extension View {
    func liveSessionLinkCover(_ model: Gate1AppModel) -> some View {
        modifier(LiveSessionLinkCover(model: model))
    }
}
