import SwiftUI
import SessionKit

/// "Mark complete" on the playback screen, once the listener is past the end of the body (#2393): the first
/// reference list or back matter of a text or PDF, or three quarters of the way through anything without one.
/// Before then it takes no room. It is the Library swipe's action, so it has the same undo.
struct PlaybackMarkCompleteButton: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        if let row = offeredRow {
            Button { model.markItemCompleted(id: row.id) } label: {
                Label("Mark complete", systemImage: "checkmark.circle").minimumTapTarget()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .accessibilityIdentifier("playback.markComplete.button")
        }
    }

    /// The playing item's Library row, when completion is offered at the playing position. The position test comes
    /// first because it is one comparison; the row lookup runs only once the offer is on.
    private var offeredRow: LibraryItemRow? {
        let snapshot = model.snapshot
        let item = model.selectedItem
        guard snapshot.itemId == item.id, !snapshot.isRecording,
              snapshot.targetType != TargetType.assistantTurnTTS.rawValue,
              snapshot.targetType != TargetType.summaryTurnTTS.rawValue else { return nil }
        let offered: Bool
        if model.isMediaPlaybackSnapshot {
            offered = PlaybackCompletionOffer.isOffered(
                mediaTimeMs: snapshot.currentMediaTimeMs ?? 0, durationMs: snapshot.currentPlaybackDurationMs ?? 0)
        } else {
            let length = item.timelineSource.characterCount > 0 ? item.timelineSource.characterCount : item.text.count
            offered = PlaybackCompletionOffer.isOffered(
                textOffset: snapshot.currentTextStart ?? 0, textLength: length, source: item.timelineSource)
        }
        guard offered, let row = model.libraryItems.first(where: { $0.id == item.id }),
              ItemQuickAction.completionAction(for: row) == .markComplete else { return nil }
        return row
    }
}
