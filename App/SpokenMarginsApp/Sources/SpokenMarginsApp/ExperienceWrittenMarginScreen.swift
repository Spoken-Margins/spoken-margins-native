import SessionKit
import SwiftUI

/// Playback's written Margin screen: reads the app model and hands the shared sheet plain values and closures (#3491).
struct ExperienceWrittenMarginScreen: View {
    @EnvironmentObject private var model: Gate1AppModel

    private var text: Binding<String> {
        Binding(
            get: { model.writtenMarginDraft?.text ?? "" },
            set: { model.updateWrittenMarginText($0) }
        )
    }

    var body: some View {
        if let draft = model.writtenMarginDraft {
            MarginWritingSheet(
                anchorLabel: "\(draft.targetDescription) · \(draft.progressPercent)%",
                anchorDetail: draft.itemTitle,
                anchorAccessibilityLabel: "Saved position for \(draft.itemTitle), \(draft.targetDescription), \(draft.progressPercent) percent",
                reply: draft.replyChoice,
                toggleReply: model.toggleReplyOfCurrentMargin,
                text: text,
                saveTitle: draft.priorWasPlaying ? "Save & resume" : "Save Margin",
                error: model.lastError,
                onSave: { model.saveWrittenMargin(text: draft.text) },
                onCancel: model.cancelWrittenMargin
            )
        }
    }
}
