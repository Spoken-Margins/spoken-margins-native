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
                        let button = model.footnoteCardButton
                        FootnoteCardBody(
                            card: card, reading: model.footnoteCardIsReading, button: button,
                            onButton: { if let button { model.footnoteCardButtonPressed(button) } })
                    }
                }
            }
        }
    }
}

/// The button on the card in "Chime where cited" (Design, Screens): Hear note while a note is offered, Stop note while
/// it reads.
enum FootnoteCardButton: Equatable {
    case hearNote
    case stopNote

    var title: String {
        switch self {
        case .hearNote: "Hear note"
        case .stopNote: "Stop note"
        }
    }

    var symbol: String {
        switch self {
        case .hearNote: "speaker.wave.2"
        case .stopNote: "stop.fill"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .hearNote: "footnoteCard.hearNote"
        case .stopNote: "footnoteCard.stopNote"
        }
    }
}

/// The card's drawing, with everything it needs handed in, so a layout test can draw it at each text size without a
/// `Gate1AppModel` (as `PinnedMarginCardBody`).
struct FootnoteCardBody: View {
    let card: FootnoteCard
    let reading: Bool
    var button: FootnoteCardButton?
    var onButton: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The note's words, up to this many lines; the full note is in the text reader's notes chapter, so there is no
    /// "More" sheet (Design, Screens). The Design says six. At the accessibility sizes the card gets four instead: the
    /// header wraps there, and six lines of body plus a wrapped header ran 1.7 pt past the 430 pt budget (half the screen,
    /// what is left for the title, the transport and the Auto-play row) at accessibility3 on iPhone 17 (#4991). The budget
    /// is the rule, so the cap moves, not the number; two lines of slack keep a font-metric change from tipping it again.
    ///
    /// The chime mode's button (Hear note, Stop note) takes room too, and the budget does not grow for it, so the note gets
    /// two lines fewer with it: four, and at the accessibility sizes two.
    static func bodyLineLimit(for size: DynamicTypeSize, hasButton: Bool = false) -> Int {
        let lines = size.isAccessibilitySize ? 4 : 6
        return hasButton ? lines - 2 : lines
    }

    private var isLargeText: Bool { dynamicTypeSize >= .xLarge }

    var body: some View {
        // Laid out like the friend's Margin card above the same passage, but with its own symbol and no name, so the two
        // can't be mistaken for each other: a Margin card always names a person, this one never does. The same white at
        // 85% (the words) and 10% (the fill) as that card, on the same always-dark `listeningBackground`; the two uses are
        // listed in `AppColorUsageGuardTests.systemColorBaseline`. `AppColors.watch*` is not an option: only `Playback*`
        // files may use it, and a new tint needs its own audited pair.
        VStack(alignment: .leading, spacing: 8) {
            // One element that reads "Footnote 3. <the whole note>". It posts no announcement: narration is already reading
            // it. The button, when there is one, is its own element after it: "Hear note, button".
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
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(Self.bodyLineLimit(for: dynamicTypeSize, hasButton: button != nil))
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("footnoteCard.body")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card.voiceOverLabel)
            .accessibilityIdentifier("footnoteCard")
            if let button {
                Button(action: onButton) {
                    Label(button.title, systemImage: button.symbol)
                        .lineLimit(isLargeText ? nil : 1)
                        .minimumScaleFactor(isLargeText ? 1 : 0.8)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier(button.accessibilityIdentifier)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(AppColors.listeningBackground)
    }
}
