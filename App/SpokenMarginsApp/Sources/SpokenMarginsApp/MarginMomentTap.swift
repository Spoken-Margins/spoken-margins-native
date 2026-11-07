import Foundation
import SessionKit
import SessionKitPersistence

/// What `playMarginMoment` needs from the store: the Margin's session and the item's detail (#2505).
struct MarginMomentLoad: Sendable {
    let target: MarginMomentTarget
    let detail: ItemDetailState

    static let unavailable = SessionKitError.invalidCommandForState("This Margin's listening session is unavailable.")

    /// The same reads on the calling thread, for callers that use the result on the next line.
    static func read(row: MarginRow, store: SQLiteSessionStore, detail: (String) throws -> ItemDetailState) throws -> MarginMomentLoad {
        let i = row.interjection
        guard let target = try MarginMomentTarget.find(store: store, sessionId: i.sessionId, itemId: i.itemId, interjectionId: i.id) else { throw unavailable }
        return MarginMomentLoad(target: target, detail: try detail(target.session.itemId))
    }
}

/// A listener's tap on a Margin's moment (#2505). The reads run off the main thread, and the screen the tap came from
/// stays until they are done, as for `openItemFromTap`; a newer open, leaving that screen, or a recording starting
/// meanwhile drops the late result.
@MainActor
enum MarginMomentTap {
    static func start(_ row: MarginRow, model: Gate1AppModel) {
        guard !model.rejectNavigationOrSessionMutationWhileRecording("play_margin_moment") else { return }
        let store: SQLiteSessionStore
        do { store = try model.requireStore() } catch { return model.reportFailure(error, context: "Could not play this Margin's position") }
        let generation = model.backgroundRefresh.beginOpen()
        let from = model.screen
        model.backgroundRefresh.holdOpen(Task { [weak model] in
            guard let model else { return }
            let i = row.interjection
            let loaded: Result<MarginMomentLoad, Error>
            do {
                let found = try await StoreReader(store).read(priority: .userInitiated) {
                    try MarginMomentTarget.find(store: $0, sessionId: i.sessionId, itemId: i.itemId, interjectionId: i.id)
                }
                guard let found else { throw MarginMomentLoad.unavailable }
                loaded = .success(MarginMomentLoad(target: found, detail: try await model.loadItemDetailOffMain(id: found.session.itemId, store: store)))
            } catch { loaded = .failure(error) }
            guard !Task.isCancelled, model.backgroundRefresh.isCurrentOpen(generation), model.screen == from, !model.recordingNavigationIsLocked else { return }
            switch loaded {
            case .success(let load): model.hangTelemetry.labels.scoped("playMarginMomentTap") { _ = model.playMarginMoment(row, loaded: load) }
            case .failure(let error): model.reportFailure(error, context: "Could not play this Margin's position")
            }
        })
    }
}
