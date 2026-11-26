import SessionKit
import SwiftUI

/// The Playback screen's top-left toolbar item. It is its own type so a test can host it and check that the bar's
/// content does not depend on scroll state (#4739).
///
/// One meaning for the top-left arrow on every tab: leave the screen. The exception is the Timeline editor with the
/// keyboard up, where the tab switch is hidden and this is the way back to Now (#4027).
///
/// On Now the Library arrow is always drawn here (#5329). It used to live beside the title, with an invisible copy in
/// the bar so the bar could not resize as the title scrolled (#4739); iOS 26 drew an empty glass pill around that copy.
/// Nothing in the bar may depend on scroll state, so this type takes no scroll input at all.
struct PlaybackLeadingToolbar<LibraryExit: View>: ToolbarContent {
    let pane: PlaybackLeadingControl.Pane
    let timelineEditorHasFocus: Bool
    let returnToNow: () -> Void
    @ViewBuilder let libraryExit: () -> LibraryExit

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        switch PlaybackLeadingControl.control(pane: pane, timelineEditorHasFocus: timelineEditorHasFocus) {
        case .libraryExit:
            ToolbarItem(placement: .topBarLeading) {
                libraryExit()
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
