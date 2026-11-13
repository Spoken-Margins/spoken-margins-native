import SessionKit
import SwiftUI

/// Whom a Margin being recorded or written answers, with the control that stops it being a reply and brings it back
/// (#473, owner 2026-10-25; the words and the ×, #3890). While it answers, the row ends with an × ("Stop replying");
/// after, it reads "Not a reply" with a text button, "Reply to Sam". The words carry the state, so colour is never the
/// only signal, and the row takes its colour from the surface it sits on: `controlColor` is the evergreen of the other
/// text buttons on the cream writing sheet, and `listeningAccent` on the dark recording screen.
struct ExperienceReplyChoiceRow: View {
    let choice: MarginReplyChoice
    let captionColor: Color
    let controlColor: Color
    let identifierPrefix: String
    let switchReply: () -> Void

    var body: some View {
        if let caption = choice.caption, let title = choice.switchTitle {
            if choice.isIndependent {
                VStack(alignment: .leading, spacing: 4) {
                    captionLabel(caption, systemImage: "arrowshape.turn.up.left")
                    Button(action: switchReply) {
                        Text(title).frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(controlColor)
                    .accessibilityIdentifier("\(identifierPrefix).replyToggle.button")
                }
            } else {
                HStack(alignment: .top, spacing: 4) {
                    captionLabel(caption, systemImage: "arrowshape.turn.up.left.fill")
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: switchReply) {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(controlColor)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("\(identifierPrefix).replyToggle.button")
                }
            }
        }
    }

    private func captionLabel(_ caption: String, systemImage: String) -> some View {
        Label(caption, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(captionColor)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("\(identifierPrefix).replyCaption.label")
    }
}
