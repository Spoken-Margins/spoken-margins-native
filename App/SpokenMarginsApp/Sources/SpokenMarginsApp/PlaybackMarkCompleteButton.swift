import SwiftUI
import SessionKit

/// "Mark complete" on the playback screen, once the listener is past the end of the body (#2393): the first
/// reference list or back matter of a text or PDF, or three quarters of the way through anything without one.
/// Before then it takes no room. It is the Library swipe's action, so it has the same undo.
struct PlaybackMarkCompleteButton: View {
    @EnvironmentObject private var model: Gate1AppModel
    /// The button follows the playhead, so it is a playhead view: the model publishes a progress tick to the clock
    /// and not to the screens (#2074), and a view with no stored state would otherwise wait for an unrelated
    /// change before testing the position again (#2968).
    @State private var playbackTick = 0

    var body: some View {
        let _ = playbackTick
        let positionOffered = self.positionOffered
        let row = positionOffered ? libraryRow : nil
        let presence = PlaybackCompletionOffer.presence(positionOffered: positionOffered, row: row)
        Group {
            if presence == .offered, let row {
                Button { model.markItemCompleted(id: row.id) } label: {
                    Label("Mark complete", systemImage: "checkmark.circle").minimumTapTarget()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .accessibilityIdentifier("playback.markComplete.button")
            }
        }
        .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
        // Past the position test and still hidden: say why in Diagnostics, once per change (#2968).
        .onCompatibleChange(of: presence) { value in
            if value == .noLibraryRow || value == .alreadyComplete {
                model.recordDeveloperDiagnostic("playback.markComplete.hidden", ["reason": value.rawValue, "item": model.selectedItem.id])
            }
        }
    }

    /// The playing item's Library row; looked up only once the position test has passed.
    private var libraryRow: LibraryItemRow? {
        model.libraryItems.first(where: { $0.id == model.selectedItem.id })
    }

    /// Whether the playing position is past the point where completion is offered. The position test comes first
    /// because it is one comparison; the row lookup runs only once the offer is on. The playhead is read from the
    /// clock, the source the scrubber reads.
    private var positionOffered: Bool {
        let snapshot = model.snapshot
        let item = model.selectedItem
        guard snapshot.itemId == item.id, !snapshot.isRecording,
              snapshot.targetType != TargetType.assistantTurnTTS.rawValue,
              snapshot.targetType != TargetType.summaryTurnTTS.rawValue else { return false }
        let position = model.playbackClock.position
        if model.isMediaPlaybackSnapshot {
            return PlaybackCompletionOffer.isOffered(
                mediaTimeMs: position.mediaTimeMs ?? 0, durationMs: snapshot.currentPlaybackDurationMs ?? 0)
        }
        let length = item.timelineSource.characterCount > 0 ? item.timelineSource.characterCount : item.text.count
        return PlaybackCompletionOffer.isOffered(
            textOffset: position.textStart ?? 0, textLength: length, source: item.timelineSource)
    }
}
