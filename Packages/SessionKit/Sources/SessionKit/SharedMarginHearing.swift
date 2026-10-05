import Foundation

/// Which shared Margins are new to this listener (#469). A shared Margin is new until its voice
/// first plays, by any route; the repository records that time once
/// (`markImportedCommentaryInterjectionHeard`).
public enum SharedMarginHearing {
    /// `records` (an item's shared Margins by layer) with `heard` in place of its older copy.
    public static func replacing(
        _ heard: ImportedCommentaryInterjection,
        in records: [String: [ImportedCommentaryInterjection]]
    ) -> [String: [ImportedCommentaryInterjection]] {
        var records = records
        records[heard.layerId] = records[heard.layerId]?.map { $0.id == heard.id ? heard : $0 }
        return records
    }

}
