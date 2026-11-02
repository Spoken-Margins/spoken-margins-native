import Foundation

/// Which shared Margins are new to this listener (#469). A shared Margin is new until its voice
/// first plays, by any route; the repository records that time once
/// (`markImportedCommentaryInterjectionHeard`).
public enum SharedMarginHearing {
    /// `margin` as it reads once its voice has played at `date`: the first time sticks. The screen shows this at once;
    /// the repository records the same fact (`markImportedCommentaryInterjectionHeard`) off the main thread (#2509).
    public static func heard(_ margin: ImportedCommentaryInterjection, at date: Date) -> ImportedCommentaryInterjection {
        var margin = margin
        if margin.firstHeardAt == nil { margin.firstHeardAt = date }
        return margin
    }

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
