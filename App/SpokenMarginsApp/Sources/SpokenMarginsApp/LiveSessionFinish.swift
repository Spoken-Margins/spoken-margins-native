import Foundation

/// How the live session screen closes on a saved or discarded session (#4168). Save as Notes used to open the item
/// while the screen was still up, which replaced the screen under its cover, and let go of the session, so the cover
/// was left on the setup card for a new session. Now the screen closes first and the item opens once it has gone, and
/// a closing screen never shows the setup card.
@MainActor
final class LiveSessionFinish: ObservableObject {
    enum State: Equatable {
        case open
        case saving
        case saved(Gate1AppModel.SavedLiveSession)
        case closed
    }

    @Published private(set) var state: State = .open
    private var isGone = false

    /// Only an open screen with no session shows the setup card.
    var showsSetup: Bool { state == .open }
    var isSaving: Bool { state != .open }

    /// False while a save is under way or done, so a second tap never saves the session twice.
    func beginSaving() -> Bool {
        guard state == .open else { return false }
        state = .saving
        return true
    }

    /// The save failed: the session is still there to save again.
    func saveFailed() {
        if state == .saving { state = .open }
    }

    /// The save finished. The screen closes, and the item opens once it has gone; if it already went (Back during
    /// Saving…, or a cover dropped by its presenter) the item opens now.
    func saved(_ saved: Gate1AppModel.SavedLiveSession, dismiss: () -> Void, open: (Gate1AppModel.SavedLiveSession) -> Void) {
        guard state == .open || state == .saving else { return }
        state = .saved(saved)
        if isGone { screenGone(open: open) } else { dismiss() }
    }

    func discarded() { state = .closed }

    /// The screen is showing, or showing again after a cover of its own (recording, writing) went away.
    func screenAppeared() { isGone = false }

    /// The screen has gone. A saved session's item opens, once.
    func screenGone(open: (Gate1AppModel.SavedLiveSession) -> Void) {
        isGone = true
        guard case .saved(let saved) = state else { return }
        state = .closed
        open(saved)
    }
}
