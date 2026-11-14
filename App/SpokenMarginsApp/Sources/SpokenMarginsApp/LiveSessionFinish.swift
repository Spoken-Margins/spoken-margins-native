import Foundation
import SessionKit

/// The live session screen's view of `LiveSessionFinishFlow` (#4168): the rules are in SessionKit and host-tested,
/// this publishes the state so the screen redraws. It keeps the flow's calls, so the screen reads as before.
@MainActor
final class LiveSessionFinish: ObservableObject {
    typealias State = LiveSessionFinishFlow<Gate1AppModel.SavedLiveSession>.State

    @Published private(set) var state: State = .open
    private var flow = LiveSessionFinishFlow<Gate1AppModel.SavedLiveSession>()

    var showsSetup: Bool { flow.showsSetup }
    var isSaving: Bool { flow.isSaving }

    func beginSaving() -> Bool {
        defer { publish() }
        return flow.beginSaving()
    }

    func saveFailed() {
        flow.saveFailed()
        publish()
    }

    func saved(_ saved: Gate1AppModel.SavedLiveSession, dismiss: () -> Void, open: (Gate1AppModel.SavedLiveSession) -> Void) {
        flow.saved(saved, dismiss: dismiss, open: open)
        publish()
    }

    func discarded() {
        flow.discarded()
        publish()
    }

    func screenAppeared() { flow.screenAppeared() }

    func screenGone(open: (Gate1AppModel.SavedLiveSession) -> Void) {
        flow.screenGone(open: open)
        publish()
    }

    private func publish() {
        if state != flow.state { state = flow.state }
    }
}
