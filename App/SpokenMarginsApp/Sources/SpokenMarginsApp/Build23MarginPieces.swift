import Foundation
import SessionKit
import SessionKitSharing
import SwiftUI

// The parts of a Margin's card that the reply sheet's editor and the Share Margins list's card both draw (#4647). Each
// keeps the identifiers it had inside `Build23MarginEditor`, so tests and the journeys find them in either place.

/// The line under "Your friend gets" that says what the friend receives for the version shown (#3839).
struct Build23VersionCaption: View {
    let representation: ShareMarginRepresentationChoice
    let marginID: String

    static func text(for representation: ShareMarginRepresentationChoice) -> String {
        switch representation {
        case .original: ShareReviewCardWords.captionAsRecorded
        case .cleaned: ShareReviewCardWords.captionWithoutUms
        case .textOnly: ShareReviewCardWords.captionWordsOnly
        }
    }

    var body: some View {
        Text(Self.text(for: representation))
            .font(.footnote)
            .foregroundStyle(AppColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("build23.sender.representation.caption.\(marginID)")
    }
}

/// "Read aloud on their phone" for a Margin that goes as Words only (#3427), with the caption that says what happens.
struct Build23ReadAloudControl: View {
    let margin: Build23SharingMarginSnapshot
    let send: (Build23SenderAction) -> Void

    var body: some View {
        // A text Margin is read aloud by the friend's phone unless you ask it not to; they can change it (#3427).
        Toggle(
            "Read aloud on their phone",
            isOn: Binding(
                get: { margin.readAloud },
                set: { send(.setReadAloud(id: margin.id, readAloud: $0)) }
            )
        )
        .accessibilityIdentifier("build23.sender.readAloud.\(margin.id)")
        Text(margin.readAloud
            ? "Their phone reads it out as your words, and Skim stops at it. They can turn that off."
            : "They read it on the screen instead. Skim still stops at it, with nothing read. They can turn reading on.")
            .font(.caption)
            .foregroundStyle(AppColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Where it lands": the caption and the two anchor fields, without the disclosure around them.
struct Build23WhereItLandsFields: View {
    let margin: Build23SharingMarginSnapshot
    let send: (Build23SenderAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ShareReviewCardWords.whereItLandsCaption)
                .font(.footnote)
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            AppTextField(
                ShareReviewCardWords.wordsJustBefore,
                text: Binding(
                    get: { margin.anchorBefore },
                    set: { send(.setAnchorBefore(id: margin.id, text: $0)) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(ShareReviewCardWords.wordsJustBefore)
            .accessibilityIdentifier("build23.sender.anchor.before.\(margin.id)")

            AppTextField(
                ShareReviewCardWords.wordsJustAfter,
                text: Binding(
                    get: { margin.anchorAfter },
                    set: { send(.setAnchorAfter(id: margin.id, text: $0)) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(ShareReviewCardWords.wordsJustAfter)
            .accessibilityIdentifier("build23.sender.anchor.after.\(margin.id)")
        }
    }
}

/// #3839's quiet note about where the Margin will land, when there is one.
struct Build23PlacementNote: View {
    let margin: Build23SharingMarginSnapshot

    var body: some View {
        if let note = margin.placementNote {
            Text(note)
                .font(.footnote)
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("build23.sender.margin.placement-note.\(margin.id)")
        }
    }
}

/// "Private note, not sent" and the note, when the Margin has one.
struct Build23PrivateNoteView: View {
    let margin: Build23SharingMarginSnapshot

    var body: some View {
        if let privateNote = margin.privateNote,
           !privateNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Build23StatusLabel(
                    icon: "lock.fill",
                    title: ShareReviewCardWords.privateNote,
                    tint: AppColors.secondaryText
                )
                Text(privateNote)
                    .font(.body)
                    .foregroundStyle(AppColors.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("build23.sender.private-note.\(margin.id)")
        }
    }
}

/// The Margin's failure and warning lines (`ShareCleanupWords.Failure`), unchanged.
struct Build23MarginFailureLines: View {
    let margin: Build23SharingMarginSnapshot

    var body: some View {
        if let preparationMessage = margin.preparationMessage, !preparationMessage.isEmpty {
            Build23StatusLabel(
                icon: margin.hasCleanedVoice ? "checkmark.circle.fill" : "info.circle.fill",
                title: preparationMessage,
                tint: margin.hasCleanedVoice ? AppColors.evergreen : AppColors.secondaryText
            )
        }
        if let warning = margin.warning, !warning.isEmpty {
            Build23StatusLabel(icon: "exclamationmark.triangle.fill", title: warning, tint: AppColors.plum)
        }
    }
}

/// The token editor's actions: a word is taken out or put back; a pause is shortened or put back.
enum Build23TokenToggle {
    static func action(for token: Build23SharingReviewTokenSnapshot, marginID: String) -> Build23SenderAction? {
        switch token.kind {
        case .word:
            guard let segmentID = token.segmentID else { return nil }
            return .toggleTranscriptWord(draftID: marginID, segmentID: segmentID)
        case .pause:
            guard let decisionID = token.decisionID else { return nil }
            return .setCleanupDecision(draftID: marginID, decisionID: decisionID, accepted: !token.isRemoved)
        }
    }
}

/// "Undo", "Redo" and "Undo all edits" for one Margin.
struct Build23EditHistoryButtons: View {
    let margin: Build23SharingMarginSnapshot
    let send: (Build23SenderAction) -> Void

    var body: some View {
        AdaptiveStack(spacing: 10) {
            Button("Undo", systemImage: "arrow.uturn.backward") {
                send(.undo(id: margin.id))
            }
            .disabled(!margin.canUndo)
            .accessibilityIdentifier("build23.sender.editor.undo.\(margin.id)")

            Button("Redo", systemImage: "arrow.uturn.forward") {
                send(.redo(id: margin.id))
            }
            .disabled(!margin.canRedo)
            .accessibilityIdentifier("build23.sender.editor.redo.\(margin.id)")

            if margin.canUndo || margin.automaticCleanupEnabled || margin.hasCleanedVoice {
                AdaptiveSpacer()
                Button("Undo all edits") {
                    send(.restoreOriginal(id: margin.id))
                }
                .accessibilityIdentifier("build23.sender.editor.restore.\(margin.id)")
            }
        }
        .buttonStyle(.bordered)
    }
}
