import Foundation

/// How the item screen draws "Review Margins" (#3854). Beside the two start choices it is a quiet link, not a third
/// peer button (#3219), but quiet means no fill, never grey: a grey fill with grey text is how iOS draws a disabled
/// button, and the link is always live. The outline is a shape cue, so it reads as tappable without colour.
public enum ItemMarginsLinkStyle: Equatable, Sendable {
    /// An evergreen outline, no fill: beside the two start choices.
    case outline
    /// The `.bordered` evergreen button: when no friend Margins wait and the link is the only Margins action.
    case bordered

    public static func style(quiet: Bool) -> ItemMarginsLinkStyle {
        quiet ? .outline : .bordered
    }
}
