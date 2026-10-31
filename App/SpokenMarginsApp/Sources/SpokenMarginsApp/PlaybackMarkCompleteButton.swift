import SwiftUI
import SessionKit

/// "Mark complete" and "Share" on the playback screen, once the listener is past the end of the body (#2393): the first
/// reference list or back matter of a text or PDF, or three quarters of the way through anything without one.
/// Before then it takes no room. Mark complete is the Library swipe's action, so it has the same undo. Share opens
/// the export screen, as it does after the item finishes, and stays when Mark complete is hidden for a Library-row reason.
///
/// The playback screen computes `presence` on each playback tick (it follows the clock) and passes it in, so this
/// view's body runs when the answer changes. A view that shows nothing does not get `onAppear`, `onChange` or a
/// clock subscription, which is why the playhead follow and the diagnostics live on views that always exist (#2968).
struct PlaybackMarkCompleteButton: View {
    @EnvironmentObject private var model: Gate1AppModel
    let presence: PlaybackCompletionOffer.Presence

    var body: some View {
        if PlaybackCompletionOffer.offersShare(presence) {
            HStack(spacing: 24) {
                if presence == .offered {
                    Button { model.markItemCompleted(id: model.selectedItem.id) } label: {
                        Label("Mark complete", systemImage: "checkmark.circle").minimumTapTarget()
                    }
                    .accessibilityIdentifier("playback.markComplete.button")
                }
                Button(action: model.openExport) {
                    Label("Share", systemImage: "square.and.arrow.up").minimumTapTarget()
                }
                .accessibilityIdentifier("playback.share.button")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
        }
    }
}

/// Says in Diagnostics why Mark complete is hidden past the offer point (#2968). Zero size, always on screen, so its
/// `onAppear` and `onChange` run whether or not the button shows.
struct PlaybackMarkCompleteDiagnostics: View {
    @EnvironmentObject private var model: Gate1AppModel
    let presence: PlaybackCompletionOffer.Presence
    @State private var previous: PlaybackCompletionOffer.Presence?

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { record(presence) }
            .onCompatibleChange(of: presence) { record($0) }
    }

    private func record(_ next: PlaybackCompletionOffer.Presence) {
        let before = previous
        previous = next
        guard PlaybackCompletionOffer.shouldRecordHidden(from: before, to: next) else { return }
        model.recordDeveloperDiagnostic("playback.markComplete.hidden", ["reason": next.rawValue, "item": model.selectedItem.id])
    }
}

extension Gate1AppModel {
    /// What the playback screen shows for completion at the playing position. The position test comes first because
    /// it is one comparison; the Library row lookup runs only once the offer is on. The playhead is read from the
    /// clock, the source the scrubber reads.
    var playbackCompletionPresence: PlaybackCompletionOffer.Presence {
        let item = selectedItem
        guard snapshot.itemId == item.id, !snapshot.isRecording,
              snapshot.targetType != TargetType.assistantTurnTTS.rawValue,
              snapshot.targetType != TargetType.summaryTurnTTS.rawValue else { return .notYet }
        let position = playbackClock.position
        let positionOffered: Bool
        if isMediaPlaybackSnapshot {
            positionOffered = PlaybackCompletionOffer.isOffered(
                mediaTimeMs: position.mediaTimeMs ?? 0, durationMs: snapshot.currentPlaybackDurationMs ?? 0)
        } else {
            let length = item.timelineSource.characterCount > 0 ? item.timelineSource.characterCount : item.text.count
            positionOffered = PlaybackCompletionOffer.isOffered(
                textOffset: position.textStart ?? 0, textLength: length, source: item.timelineSource)
        }
        return PlaybackCompletionOffer.presence(
            positionOffered: positionOffered,
            row: positionOffered ? libraryItems.first(where: { $0.id == item.id }) : nil)
    }
}
