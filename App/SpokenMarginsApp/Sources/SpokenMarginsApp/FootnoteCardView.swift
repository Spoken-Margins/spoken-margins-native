import SwiftUI
import SessionKit

/// The Footnote card in the Now screen's pinned slot while a note is read where it is cited (#3777, Design PR 5). It
/// shows only for that note and is gone when the narrator goes on with the text. A friend's pinned Margin card wins:
/// `Gate1AppModel.footnoteCard` is nil while one is up.
///
/// The player's current chunk is not published, and the playhead holds at the citing sentence while a note is read, so
/// no playback tick moves this view: it asks the player twice a second, and only while a note could be playing.
struct FootnoteCardPinnedView: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        Group {
            if model.footnoteCardMayShow {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    if let card = model.footnoteCard {
                        FootnoteCardBody(card: card, reading: model.footnoteCardIsReading)
                    }
                }
            }
        }
    }
}

/// The card's drawing, with everything it needs handed in, so a layout test can draw it at each text size without a
/// `Gate1AppModel` (as `PinnedMarginCardBody`).
struct FootnoteCardBody: View {
    let card: FootnoteCard
    let reading: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The note's words, up to this many lines; the full note is in the text reader's notes chapter, so there is no
    /// "More" sheet (Design, Screens).
    static let bodyLineLimit = 6

    private var isLargeText: Bool { dynamicTypeSize >= .xLarge }

    var body: some View {
        // Laid out like the friend's Margin card above the same passage, but with its own symbol and no name, so the two
        // can't be mistaken for each other: a Margin card always names a person, this one never does. Its greys are the
        // listening screen's token, not white at an alpha, which `ExperienceColorContrastGuardTests` counts per file.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "text.append")
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
                Text(card.header(reading: reading))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(isLargeText ? nil : 1)
                    .minimumScaleFactor(isLargeText ? 1 : 0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("footnoteCard.headline")
                Spacer(minLength: 0)
            }
            Text(card.body)
                .font(.footnote)
                .foregroundStyle(AppColors.watchSecondary)
                .lineLimit(Self.bodyLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityHidden(true)
                .accessibilityIdentifier("footnoteCard.body")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.watchSecondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
        // One element that reads "Footnote 3. <the whole note>". It posts no announcement: narration is already reading it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.voiceOverLabel)
        .accessibilityIdentifier("footnoteCard")
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(AppColors.listeningBackground)
    }
}
