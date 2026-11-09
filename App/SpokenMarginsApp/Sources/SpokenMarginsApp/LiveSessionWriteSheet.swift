import SessionKit
import SwiftUI

/// The sheet for writing a Margin in a live session: the shared writing sheet with the live session's place field
/// and position nudge in its accessory slot (#3491). The draft lives here; Save hands it to `onSave` and the parent
/// dismisses the sheet.
struct LiveSessionWriteSheet: View {
    let kind: ElsewhereKind
    let anchorTitle: String
    /// "Chapter 3", "about 1:23:10": where the session is now, shown on the anchor line.
    let anchorLabel: String
    /// The predicted source position at a time, with the listener's slide in milliseconds added.
    let predictedPosition: (_ now: Date, _ adjustmentMs: Int) -> LiveSessionPositionMap.Position?
    let onSave: (_ text: String, _ whereNote: String?, _ adjustmentMs: Int) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @State private var whereNote = ""
    @State private var adjustmentMs = 0

    var body: some View {
        MarginWritingSheet(
            anchorLabel: anchorLabel,
            anchorDetail: anchorTitle,
            anchorAccessibilityLabel: "Live session \(anchorTitle), \(anchorLabel)",
            reply: nil,
            toggleReply: {},
            text: $text,
            saveTitle: "Save Margin",
            error: nil,
            onSave: {
                onSave(text, whereNote.isEmpty ? nil : whereNote, adjustmentMs)
            },
            onCancel: onCancel
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if kind != .meeting {
                    LiveSessionPlaceField(
                        prompt: kind == .paper ? "Page (optional)" : "Page, chapter or percent (optional)",
                        defaultUnit: LiveSessionPlace.defaultUnit(for: kind), text: $whereNote
                    )
                }
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    if let position = predictedPosition(context.date, adjustmentMs) {
                        PositionNudgeRow(
                            label: adjustmentMs == 0 ? position.label : "you set \(LiveSessionPositionMap.clock(position.ms))",
                            adjustmentMs: $adjustmentMs
                        )
                    }
                }
            }
        }
    }
}
