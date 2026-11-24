import SessionKit
import SwiftUI

/// The Playback screen's top-left toolbar item. It is its own type so a test can host it and check that the bar's
/// content does not depend on scroll state (#4739).
///
/// One meaning for the top-left arrow on every tab: leave the screen. The exception is the Timeline editor with the
/// keyboard up, where the tab switch is hidden and this is the way back to Now (#4027).
///
/// The Library arrow is in the bar in every state of the Now header, hidden while the header shows it. Adding and
/// removing the item as the header scrolled in and out changed the bar's size at large text, which moved the header
/// across its visibility threshold and flipped the item again, without end. Nothing in the bar may depend on scroll
/// state, so this type takes the raw inputs and never wraps an item in a condition on them.
struct PlaybackLeadingToolbar<LibraryExit: View>: ToolbarContent {
    let pane: PlaybackLeadingControl.Pane
    let timelineEditorHasFocus: Bool
    let nowHeaderIsVisible: Bool
    let returnToNow: () -> Void
    @ViewBuilder let libraryExit: () -> LibraryExit

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        let slot = PlaybackLeadingControl.slot(
            pane: pane, timelineEditorHasFocus: timelineEditorHasFocus, nowHeaderIsVisible: nowHeaderIsVisible)
        switch slot.kind {
        case .libraryExit:
            ToolbarItem(placement: .topBarLeading) {
                libraryExit()
                    .opacity(slot.isShown ? 1 : 0)
                    .allowsHitTesting(slot.isShown)
                    .accessibilityHidden(!slot.isShown)
            }
        case .returnToNow:
            ToolbarItem(placement: .topBarLeading) {
                Button(action: returnToNow) {
                    Label("Now Playing", systemImage: "arrow.left")
                }
                .tint(AppColors.listeningAccent)
                .accessibilityIdentifier("timeline.nowPlaying.button")
            }
        }
    }
}
