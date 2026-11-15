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
    /// A photo taken for this Margin and waiting for its words (#2708): shown above the field.
    var photo: LiveSessionPhotoStore.Staged?
    /// A line above the photo, like the microphone being off when the photo was taken to be spoken about.
    var notice: String?
    /// Said above the field when the session ended while this screen was open; Save still adds the Margin (#3847).
    var endedLine: String?
    /// Save was refused because the session was saved to the Library or discarded: the draft stays, with the reason.
    var refused = false
    @State private var text = ""
    @State private var whereNote = ""
    @State private var adjustmentMs = 0

    private var lead: AnyView? {
        guard photo != nil || notice != nil else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                if let notice {
                    Text(notice).font(.subheadline).foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("liveSession.photo.notice")
                }
                if let photo { LiveSessionPhotoLead(url: photo.url, hint: nil) }
            })
    }

    var body: some View {
        MarginWritingSheet(
            anchorLabel: anchorLabel,
            anchorDetail: anchorTitle,
            anchorAccessibilityLabel: "Live session \(anchorTitle), \(anchorLabel)",
            reply: nil,
            toggleReply: {},
            text: $text,
            saveTitle: "Save Margin",
            error: refused ? "It was saved to your Library or discarded while you were writing." : nil,
            onSave: {
                onSave(text, whereNote.isEmpty ? nil : whereNote, adjustmentMs)
            },
            onCancel: onCancel,
            lead: lead,
            errorHeadline: refused
                ? "Your draft is still here. This session can't take new Margins. Copy your words before you cancel."
                : "Your draft is still here. Try saving again.",
            statusLine: endedLine
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
        .onChange(of: endedLine) { old, new in
            // Said once, when the line appears while the screen is open; a screen that opens already ended says nothing extra.
            if let text = VoiceOverAnnouncements.liveSessionEnded(from: old, to: new) {
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }
}
