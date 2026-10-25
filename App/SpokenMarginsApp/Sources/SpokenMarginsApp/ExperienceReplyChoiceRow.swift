import SessionKit
import SwiftUI

/// Whom a Margin being recorded or written answers, with the control that switches it to an independent Margin and
/// back (#473, owner 2026-10-25). The words carry the state, so colour is never the only signal.
struct ExperienceReplyChoiceRow: View {
    let choice: MarginReplyChoice
    let captionColor: Color
    let identifierPrefix: String
    let switchReply: () -> Void

    var body: some View {
        if let caption = choice.caption, let title = choice.switchTitle {
            VStack(alignment: .leading, spacing: 4) {
                Label(caption, systemImage: choice.isIndependent ? "arrowshape.turn.up.left" : "arrowshape.turn.up.left.fill")
                    .font(.subheadline)
                    .foregroundStyle(captionColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifierPrefix).replyCaption.label")
                Button(title, action: switchReply)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.listeningAccent)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("\(identifierPrefix).replyToggle.button")
            }
        }
    }
}
