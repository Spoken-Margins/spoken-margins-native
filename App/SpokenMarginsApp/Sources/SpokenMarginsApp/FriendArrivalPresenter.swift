import SwiftUI
import SessionKit

/// The item screen's hold on a friend's early tap (#3788). The screen creates it with the view and it goes with the
/// view; it is never in `Gate1AppModel`. The rule is `FriendArrivalStart`, the waiting is `FriendArrivalKeeper`
/// (SessionKit, host-tested); this reads the facts off the model and lets the view redraw when the line comes or goes.
@MainActor
final class FriendArrivalPresenter: ObservableObject {
    private let keeper: FriendArrivalKeeper

    init() {
        keeper = FriendArrivalKeeper(announce: { AccessibilityNotification.Announcement($0).post() })
        keeper.onChange = { [weak self] in self?.objectWillChange.send() }
    }

    /// "Getting the episode ready. It starts by itself." while a tap waits.
    var line: String? { keeper.line }

    /// A tap on Play or "Skip to …". Nothing is read until a tap, and while one waits the facts are read every quarter
    /// second: the first Margin's audio (a file lookup for a recording), in memory otherwise.
    func tap(_ choice: FriendArrivalStart.Choice, model: Gate1AppModel, start: @escaping @MainActor (FriendArrivalStart.Choice) -> Void) {
        keeper.tap(choice, facts: { [weak model] in
            guard let model else { return FriendArrivalKeeper.Facts(itemId: "", start: FriendArrivalStart(episodeCanStart: true, firstMargin: nil), hasMargins: false) }
            return Self.facts(model: model)
        }, start: start)
    }

    func cancel() { keeper.cancel() }

    private static func facts(model: Gate1AppModel) -> FriendArrivalKeeper.Facts {
        let itemId = model.selectedItem.id
        let entries = model.newSharedMargins(itemId: itemId)
        // The first Margin the review plays; a parent step (the listener's own Margin, heard first) has no friend audio.
        let first = SharedMarginReview.playlist(for: entries, ownMargins: model.ownMargins(itemId: itemId)).lazy.compactMap(\.entry).first
        let audio = first.map {
            FriendArrivalStart.FirstMarginAudio(
                WrittenMarginReadings.audio(for: $0.interjection, in: $0.layer, voiceFile: model.resolvedApplicationSupportAssetURL(for:)))
        }
        return FriendArrivalKeeper.Facts(
            itemId: itemId,
            start: FriendArrivalStart(startupAudio: model.selectedItemStartupAudioState, firstMargin: audio),
            hasMargins: !entries.isEmpty,
            place: "\(model.snapshot.itemId ?? "")|\(model.snapshot.sessionId ?? "")|\(model.snapshot.status.isPlaybackActive)")
    }
}
