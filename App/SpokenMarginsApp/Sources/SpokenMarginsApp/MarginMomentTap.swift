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
    /// What was playing when the tap was made. Playing a shared Margin, starting an item, Skim and transport don't
    /// touch the open gate, so a late read must also see that playback is what the tap saw.
    @MainActor private struct Playing: Equatable {
        let itemId: String?
        let sessionId: String?
        let momentId: String?
        init(_ model: Gate1AppModel) {
            itemId = model.snapshot.itemId
            sessionId = model.snapshot.sessionId
            momentId = model.marginMoment?.target.marginId
        }
    }

    static func start(_ row: MarginRow, model: Gate1AppModel) {
        guard !model.rejectNavigationOrSessionMutationWhileRecording("play_margin_moment") else { return model.recordMarginTap(.own, .refused(.recordingInProgress)) }
        // A Margin with no place has no moment (#4233). The rows route it to its details; any other caller is told why.
        guard MarginRowTap.action(for: row.interjection) == .playMoment else {
            model.recordMarginTap(.own, .refused(.noPosition))
            return model.reportFailure(MarginPlaceError.noPlace, context: "Could not play this Margin's position")
        }
        let store: SQLiteSessionStore
        do { store = try model.requireStore() } catch {
            model.recordMarginTap(.own, .refused(.storeUnavailable))
            return model.reportFailure(error, context: "Could not play this Margin's position")
        }
        let generation = model.backgroundRefresh.beginOpen()
        let from = model.screen
        let playing = Playing(model)
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
            // Each way a late result is thrown away is named, so a tap that did nothing leaves a reason (#4447).
            if let reason = MarginTapLateResult.dropReason(
                cancelled: Task.isCancelled, openIsCurrent: model.backgroundRefresh.isCurrentOpen(generation),
                stillOnTheScreenTheTapCameFrom: model.screen == from, playbackIsWhatTheTapSaw: Playing(model) == playing,
                recordingLocked: model.recordingNavigationIsLocked) {
                return model.recordMarginTap(.own, .dropped(reason))
            }
            switch loaded {
            case .success(let load):
                let played = model.hangTelemetry.labels.scoped("playMarginMomentTap") { model.playMarginMoment(row, loaded: load) }
                model.recordMarginTap(.own, played ? .started : .refused(.playFailed)) // playMarginMoment told the listener why
                // Your own written Margin: the card says "Your Margin is here", as after a Skim press to it (#4938).
                if played { model.landOnOwnWrittenMargin(row) }
            case .failure(let error):
                model.recordMarginTap(.own, .refused(.marginUnavailable))
                model.reportFailure(error, context: "Could not play this Margin's position")
            }
        })
    }
}
