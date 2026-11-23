import SwiftUI
import SessionKit

/// #4715 / #5016: the one line the app says before iOS asks about Speech Recognition. It sits in the Now pane's pinned
/// slot and shows only while `SpeechAskController` says the card is due and nothing else holds the slot (a friend's Margin
/// card or a footnote card keeps the slot first). The decisions are `SpeechRecognitionAsk`; this only draws them.
struct SpeechAskCardSlot: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject private var controller = SpeechAskController.shared
    @State private var playbackTick = 0 // bumped by each progress tick: `slotIsFree` reads the pinned card, which follows the playhead (#2074)

    var body: some View {
        let _ = playbackTick
        Group {
            if controller.isCardShowing(slotIsFree: slotIsFree) {
                SpeechAskCard(controller: controller)
            }
        }
        .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }

    /// One slot rule: a friend's Margin card, a footnote card and a locked recording all keep the slot.
    private var slotIsFree: Bool {
        NowPinnedSlot(
            friendsMarginCardShowing: model.pinnedMarginCard != nil,
            footnoteCardShowing: model.footnoteCard != nil,
            recordingIsLocked: model.recordingNavigationIsLocked
        ).isFreeForSpeechAsk
    }
}

/// The Margins tab and a Margin's own screen show the same card at their top when a re-ask came from there (search, Get
/// Transcript).
struct SpeechAskCardInList: View {
    let surface: SpeechAskController.Surface
    @ObservedObject private var controller = SpeechAskController.shared

    var body: some View {
        if controller.isCardShowing(on: surface, slotIsFree: true) {
            SpeechAskCard(controller: controller, gutter: 0)
                .padding(.bottom, 12)
        }
    }
}

struct SpeechAskCard: View {
    @ObservedObject var controller: SpeechAskController
    /// The side margin: the Now pane's slot has its own, the lists already have one.
    var gutter: CGFloat = 22
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let headline = "Want your Margins as text too?"
    static let detail = "Then you can search them and copy them into your notes."

    private var isLargeText: Bool { dynamicTypeSize >= .xLarge }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.bubble")
                    .font(.title3)
                    .foregroundStyle(AppColors.listeningAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.headline).font(.headline)
                    Text(Self.detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            let row = isLargeText ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            row {
                Button { controller.yes(model: model) } label: {
                    Text("Yes").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel("Yes, get my Margins as text")
                .accessibilityIdentifier("speechAsk.yes")
                Button { controller.notNow() } label: {
                    Text("Not now").minimumTapTarget()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityLabel("Not now")
                .accessibilityIdentifier("speechAsk.notNow")
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, gutter)
        // One announcement per ask, so VoiceOver's focus (which doesn't move) hears it, but not again when the slot frees up.
        .onAppear { if controller.shouldAnnounceCard() { AccessibilityNotification.Announcement(Self.headline).post() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speechAsk.card")
    }
}
