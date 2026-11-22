import SessionKit
import SwiftUI

/// The publisher's description under the title: its first three lines, with More to read the rest in place (#1322), on the item screen and on a show's Up next card (#3863).
/// The text is whole to VoiceOver either way; only the sighted preview is cut.
struct ItemDescriptionPreview: View {
    let text: String
    /// Prefix of the accessibility identifiers (`<prefix>.text`, `<prefix>.more`). The item screen keeps `item.description`;
    /// a show's Up next card passes its own (#3863).
    var identifierPrefix = "item.description"
    @State private var expanded = false

    init(text: String, identifierPrefix: String = "item.description") {
        self.text = text
        self.identifierPrefix = identifierPrefix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifierPrefix).text")
            if ItemMetadata.needsExpansion(text) {
                Button { expanded.toggle() } label: {
                    Text(expanded ? "Less" : "More").frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }
                    // In a List row (a show's Up next card) an automatic-style button takes a tap anywhere on the row.
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHint(expanded ? "Shows fewer lines of the description." : "Shows the whole description.")
                    .accessibilityIdentifier("\(identifierPrefix).more")
            }
        }
    }
}
