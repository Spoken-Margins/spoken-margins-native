import SessionKit
import SwiftUI

/// The playback screen's colours for a spoken note's version choice (#4779). The Listening options sheet and the line on
/// Now sit on the always-dark playback surface, so they take its colours; the note screen's copy of the control does not.
enum PlaybackSpokenNoteVersionColors {
    static let secondary = AppColors.watchSecondary
}

/// The control's card in Listening options, styled like the mixed audio card beside it (`PlaybackScreen`): white on the
/// playback control colour, the pair that card already uses.
struct PlaybackSpokenNoteVersionCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background(AppColors.watchControl.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The line on Now under the title, for a spoken note playing with Shorter pauses chosen: progress while the version is
/// made, how much shorter it is once it plays, or "As recorded for now". Nothing for As recorded.
struct SpokenNoteAudioVersionLine: View {
    @ObservedObject var clean: SpokenNoteCleanCoordinator
    let noteId: String

    var body: some View {
        if let line = SpokenNoteCleanWords.nowLine(clean.state(noteId: noteId), version: clean.version) {
            Text(line)
                .font(.subheadline)
                .foregroundStyle(AppColors.watchSecondary)
                .accessibilityIdentifier("playback.noteAudioVersion.line")
        }
    }
}
