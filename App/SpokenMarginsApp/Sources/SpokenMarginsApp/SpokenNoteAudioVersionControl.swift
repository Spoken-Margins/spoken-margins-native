import SessionKit
import SwiftUI

/// The note's audio control (#4779): As recorded, Shorter pauses or Without ums (#5342), one choice for the app, with a
/// caption that says where the version stands. The note screen shows it under Play note; Listening options shows it first, for a note.
/// Every word comes from `SpokenNoteCleanWords`.
struct SpokenNoteAudioVersionControl: View {
    enum Placement {
        case noteScreen
        case listeningOptions

        var identifier: String { self == .noteScreen ? "spokenNote.audioVersion" : "playback.noteAudioVersion" }
    }

    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var clean: SpokenNoteCleanCoordinator
    let noteId: String
    let placement: Placement

    var body: some View {
        let state = clean.state(noteId: noteId)
        let caption = SpokenNoteCleanWords.caption(state, version: clean.version)
        let blocked = model.spokenNoteVersionChangeIsBlocked
        VStack(alignment: .leading, spacing: 8) {
            // At accessibility sizes the picker is a menu that VoiceOver reads as "Note audio" and its choice, so the
            // heading above it would only say "Note audio" a second time (#5333). Segmented, the heading names the pair.
            Text(SpokenNoteCleanWords.controlLabel)
                .font(.caption.weight(.semibold))
                .accessibilityHidden(dynamicTypeSize.isAccessibilitySize)
            Picker(SpokenNoteCleanWords.controlLabel, selection: Binding(
                get: { clean.version },
                set: { chosen in
                    clean.choose(chosen, playingNoteId: model.spokenNoteIsOpenSession(noteId: noteId) ? noteId : nil)
                }
            )) {
                ForEach(SpokenNoteAudioVersion.allCases, id: \.self) { version in
                    Text(SpokenNoteCleanWords.segment(version)).tag(version)
                }
            }
            .segmentedUnlessLargeText()
            .disabled(blocked)
            .modifier(MenuChoiceValue(
                isMenu: dynamicTypeSize.isAccessibilitySize,
                value: SpokenNoteCleanWords.segment(clean.version)
            ))
            .accessibilityIdentifier(placement.identifier)

            Text(caption.line)
                .font(.footnote)
                .foregroundStyle(secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(placement.identifier).caption")
            if let second = caption.second {
                Text(second)
                    .font(.footnote)
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.offersTryAgain {
                Button(SpokenNoteCleanWords.tryAgain) { clean.tryAgain(noteId: noteId) }
                    .font(.footnote.weight(.semibold))
                    .disabled(blocked)
                    .accessibilityIdentifier("\(placement.identifier).tryAgain")
            }
        }
        .modifier(PlacementStyle(placement: placement))
        .accessibilityElement(children: .contain)
    }

    private var secondary: Color {
        placement == .listeningOptions ? PlaybackSpokenNoteVersionColors.secondary : AppColors.secondaryText
    }

    /// The menu picker's label is its title, "Note audio"; this gives it the chosen version as its value, so VoiceOver
    /// reads "Note audio, Shorter pauses" once (#5333). The segmented picker's own segments already say which is chosen.
    private struct MenuChoiceValue: ViewModifier {
        let isMenu: Bool
        let value: String

        func body(content: Content) -> some View {
            if isMenu {
                content.accessibilityValue(value)
            } else {
                content
            }
        }
    }

    private struct PlacementStyle: ViewModifier {
        let placement: Placement

        func body(content: Content) -> some View {
            switch placement {
            case .noteScreen:
                content.frame(maxWidth: .infinity, alignment: .leading)
            case .listeningOptions:
                content.modifier(PlaybackSpokenNoteVersionCard())
            }
        }
    }
}
